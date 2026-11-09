import AppKit
import BatteryCore
import Foundation
import Observation
import os
import ServiceManagement

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "ChargeControl")

@MainActor
protocol ChargeHelperRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: ChargeHelperRegistration {}

/// 特权 helper 的注册状态。规则见 docs/v1技术设计.md 21.3。
public enum ChargeHelperState: Sendable, Equatable {
    /// 没有注册过。
    case notRegistered
    /// 已注册，等待用户在“登录项与扩展”里批准。
    case requiresApproval
    case enabled
    /// App 包里找不到 helper 或 plist，或系统返回了其他状态。
    case unavailable

    enum Action { case install, approve, remove }

    var action: Action {
        switch self {
        case .notRegistered, .unavailable: .install
        case .requiresApproval: .approve
        case .enabled: .remove
        }
    }
    var canInstall: Bool { action == .install }

    init(status: SMAppService.Status?) {
        switch status {
        case nil, .notRegistered?: self = .notRegistered
        case .requiresApproval?: self = .requiresApproval
        case .enabled?: self = .enabled
        default: self = .unavailable
        }
    }
}

/// 管理 helper 的注册、批准和移除。由用户在设置页点“安装…”注册。
@MainActor
@Observable
public final class ChargeHelperService {
    public static let shared = ChargeHelperService()

    public private(set) var state: ChargeHelperState = .notRegistered
    /// 注册或移除失败时的说明，只用于日志和诊断导出。
    public private(set) var lastError: String?
    /// 安装失败时显示在设置页。系统要求用户允许（`requiresApproval`）不算失败，
    /// `register()` 报错但状态为需要允许时也按需要允许处理。
    private(set) var registrationError: String?
    /// 正在注册、重新安装或移除，设置页按钮在此期间不可用。
    private(set) var isBusy = false

    /// 本机系统版本已验证可以写入低于 80% 的上限。
    public nonisolated static var isBelowThresholdSupported: Bool {
        ManualChargeLimitPreferences.isSchemaSupported
    }

    /// 可以经 helper 写入低于 80% 的上限。
    public var isReady: Bool {
        state == .enabled && Self.isBelowThresholdSupported
    }

    @ObservationIgnored private let service: (any ChargeHelperRegistration)?
    @ObservationIgnored private let updatesAvailability: Bool
    @ObservationIgnored private let opensSystemSettings: Bool
    @ObservationIgnored private let launchState: @Sendable () async -> HelperLaunchState
    /// 本版本的 label 和其他 label 的注册对象，升级时用来注销旧版本的 helper。
    @ObservationIgnored private let label: String
    @ObservationIgnored private let registrationForLabel: (String) -> (any ChargeHelperRegistration)?
    /// 记录最近一次注册的 label。
    @ObservationIgnored private let defaults: UserDefaults
    static let registeredLabelKey = "ChargeHelperRegisteredLabel"
    /// 本版本的 LaunchDaemon plist 是否在 App 包里。
    @ObservationIgnored private let hasDaemonPlist: () -> Bool
    /// 写入路由在后台线程读取，所以单独加锁保存。
    private nonisolated static let availability = Availability()

    /// `service` 为 nil 时（测试、渲染）始终未注册。
    public init(service: SMAppService? = SMAppService.daemon(plistName: ChargeHelper.daemonPlistName)) {
        self.service = service
        self.updatesAvailability = service != nil
        self.opensSystemSettings = service != nil
        self.label = ChargeHelper.label
        self.defaults = .standard
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(ChargeHelper.daemonPlistName)
        self.hasDaemonPlist = { service != nil && FileManager.default.fileExists(atPath: plist.path) }
        if service == nil {
            self.launchState = { @Sendable in .unknown }
            self.registrationForLabel = { _ in nil }
        } else {
            self.launchState = { @Sendable in await HelperLaunchState.read(label: ChargeHelper.machServiceName) }
            self.registrationForLabel = { SMAppService.daemon(plistName: ChargeHelper.plistName(for: $0)) }
        }
        refresh()
    }

    /// 测试注册、系统批准和取消时的状态变化，不触碰系统服务。
    init(
        registration: any ChargeHelperRegistration,
        label: String = ChargeHelper.legacyLabel,
        registrationForLabel: @escaping (String) -> (any ChargeHelperRegistration)? = { _ in nil },
        defaults: UserDefaults? = nil,
        hasDaemonPlist: Bool = false
    ) {
        self.service = registration
        self.updatesAvailability = false
        self.opensSystemSettings = false
        self.launchState = { .unknown }
        self.label = label
        self.registrationForLabel = registrationForLabel
        self.hasDaemonPlist = { hasDaemonPlist }
        self.defaults = defaults ?? UserDefaults(suiteName: "ChargeHelperServiceTests-\(UUID().uuidString)")!
        refresh()
    }

    /// 给写入路由用的 helper 客户端；未批准时为 nil。可以在任意线程调用。
    public nonisolated static func readyClient() -> ChargeHelperClient? {
        availability.client
    }

    public func refresh() {
        let status = service?.status
        var newState = ChargeHelperState(status: status)
        // 系统从没见过的 label 返回 notFound（2026-11-09 本机实测，每个版本的新 label 都是这样）：
        // plist 在包里就按未注册处理，可以安装；不在才是 App 缺少 helper。
        if status == .notFound, hasDaemonPlist() { newState = .notRegistered }
        if newState != state {
            logger.info("Helper state \(String(describing: newState), privacy: .public)")
            state = newState
        }
        if state == .enabled || state == .requiresApproval { registrationError = nil }
        guard updatesAvailability else { return }
        // 未验证的新系统版本仍允许读取和释放已安装的 helper，只禁止新写入。
        Self.availability.client = state == .enabled ? ChargeHelperClient() : nil
    }

    /// 注册 helper。系统要求用户允许时打开“登录项与扩展”。
    public func register() {
        register(opensLoginItems: true)
    }

    private func register(opensLoginItems: Bool) {
        guard let service else { return }
        registrationError = nil
        var failure: String?
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = String(describing: error)
            failure = (error as NSError).localizedDescription
            logger.error("Failed to register helper: \(String(describing: error), privacy: .public)")
        }
        refresh()
        switch state {
        case .requiresApproval:
            defaults.set(label, forKey: Self.registeredLabelKey)
            if opensLoginItems { openLoginItems() }
        case .enabled:
            defaults.set(label, forKey: Self.registeredLabelKey)
        case .notRegistered, .unavailable:
            registrationError = failure ?? "SMAppService status: \(service.status.rawValue)"
        }
    }

    /// 升级后改用本版本的 label：之前注册过其他 label（0.1.10 及更早为固定 label）时，注册本版本的 helper，
    /// 再注销旧的，结束仍在运行的旧 helper。不打开系统设置，设置页显示需要允许。
    /// 旧 label 的 plist 不在本版本包里时注销可能失败，只记日志：旧 helper 发现自己的文件被替换后会退出。
    public func migrateFromPreviousLabel() async {
        guard service != nil, !isBusy else { return }
        let legacy = ChargeHelper.legacyLabel
        var previous = defaults.string(forKey: Self.registeredLabelKey)
        if previous == nil, label != legacy,
           let old = registrationForLabel(legacy), [.enabled, .requiresApproval].contains(old.status) {
            previous = legacy
        }
        guard let previous, previous != label else { return }
        isBusy = true
        defer { isBusy = false }
        logger.info("Migrating helper from \(previous, privacy: .public) to \(self.label, privacy: .public)")
        if state == .notRegistered { register(opensLoginItems: false) }
        if let old = registrationForLabel(previous) {
            do {
                try await old.unregister()
            } catch {
                logger.error("Failed to unregister previous helper: \(String(describing: error), privacy: .public)")
            }
        }
        // 本版本没注册成功时保留旧记录，下次启动再试。
        if state == .enabled || state == .requiresApproval {
            defaults.set(label, forKey: Self.registeredLabelKey)
        }
    }

    /// 重新安装：先注销再注册。用于系统设置里已打开开关、状态仍是“需要允许”，
    /// 或系统已允许但连不上 helper 的情况。这两种情况 helper 都无法响应，也就无法先释放；
    /// 标记文件保留在磁盘上，重新允许后 helper 启动时按标记续约或恢复。
    public func reinstall() async {
        guard let service, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.unregister()
        } catch {
            // 注销失败（例如本来就没有注册）仍继续注册，结果以注册后的状态为准。
            logger.error("Failed to unregister helper before reinstalling: \(String(describing: error), privacy: .public)")
        }
        refresh()
        register()
        logger.info("Helper reinstalled, state \(String(describing: self.state), privacy: .public)")
    }

    public func openLoginItems() {
        if opensSystemSettings { SMAppService.openSystemSettingsLoginItems() }
    }

    /// 移除 helper。调用前要先释放并读回确认：`unregister()` 会直接终止 helper，不会替我们恢复。
    public func unregister() async {
        guard let service else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = String(describing: error)
            logger.error("Failed to unregister helper: \(String(describing: error), privacy: .public)")
        }
        refresh()
        if state == .notRegistered { defaults.removeObject(forKey: Self.registeredLabelKey) }
    }

    /// 状态查询的超时。launchd 里有这个服务但启动失败时，连接不会立即报错，而是等到超时；
    /// 写入用的默认 8 秒对状态查询太长，设置页会长时间停在“正在检查”。
    /// launchd 报告没有加载或启动失败时不发 XPC，直接返回，不等这个超时。
    static let statusTimeout: TimeInterval = 3

    /// 读取 helper 报告的状态，用于设置页、移除前检查和诊断导出。失败时为 nil。
    public func helperStatus() async -> ChargeHelperStatus? {
        guard Self.readyClient() != nil else { return nil }
        let launch = await launchState()
        if launch.isUnreachable {
            logger.error("Helper not reachable in launchd: \(String(describing: launch), privacy: .public)")
            return nil
        }
        let client = ChargeHelperClient(timeout: Self.statusTimeout)
        return await Task.detached { try? client.status() }.value
    }

    /// 确认已允许的 helper 能连上，失败时间隔 `retryDelay` 再试一次。
    /// 不自动重新注册：2026-11-09 本机日志，helper 因签名校验不符起不来时，重新注册让系统重新核对后台项目，
    /// 把用户刚打开的开关撤回成需要允许。连不上时由用户点“重新检查”或“重新安装”。
    func connectedStatus(retryDelay: Duration = .seconds(1)) async -> ChargeHelperStatus? {
        await helperStatusRetrying(attempts: 2, delay: retryDelay)
    }

    /// 刚允许或刚注册时 launchd 可能还没加载 helper，失败后稍等再试，避免误报连接失败。
    func helperStatusRetrying(attempts: Int, delay: Duration) async -> ChargeHelperStatus? {
        for attempt in 1...max(attempts, 1) {
            if let status = await helperStatus() { return status }
            guard attempt < attempts, !Task.isCancelled else { break }
            try? await Task.sleep(for: delay)
        }
        return nil
    }

    private final class Availability: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ChargeHelperClient?

        var client: ChargeHelperClient? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

/// launchd 里 helper 任务的状态，来自 `launchctl print system/<label>`（plist 的 Label 与 MachServices 同名）。
/// 只用来提前判断连不上，不作为可用的依据；输出格式不认识时为 unknown，照常经 XPC 检查。
enum HelperLaunchState: Sendable, Equatable {
    case running
    /// launchd 里没有这个任务，例如允许时 smd 没有加载成功。
    case notLoaded
    /// launchd 启动 helper 失败，例如系统按签名拒绝启动（Launch Constraint Violation）。
    case spawnFailed
    case unknown

    var isUnreachable: Bool { self == .notLoaded || self == .spawnFailed }

    static func parse(output: String, exitCode: Int32) -> HelperLaunchState {
        guard exitCode == 0 else {
            return output.contains("Could not find service") ? .notLoaded : .unknown
        }
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let jobState = lines.first(where: { $0.hasPrefix("job state = ") }) {
            let value = jobState.dropFirst("job state = ".count)
            if value == "running" { return .running }
            if value.hasPrefix("spawn failed") { return .spawnFailed }
            return .unknown
        }
        return lines.contains("state = running") ? .running : .unknown
    }

    /// 运行 `launchctl print`，超时或运行失败时为 unknown。普通用户可以读取 system 域的任务状态。
    static func read(label: String, timeout: TimeInterval = 1) async -> HelperLaunchState {
        await withCheckedContinuation { (continuation: CheckedContinuation<HelperLaunchState, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "system/\(label)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let once = OnceResume(continuation)
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                once.resume(HelperLaunchState.parse(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                logger.error("Failed to run launchctl: \(String(describing: error), privacy: .public)")
                once.resume(.unknown)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                once.resume(.unknown)
            }
        }
    }

    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HelperLaunchState, Never>?

        init(_ continuation: CheckedContinuation<HelperLaunchState, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: HelperLaunchState) {
            let pending = lock.withLock { () -> CheckedContinuation<HelperLaunchState, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
