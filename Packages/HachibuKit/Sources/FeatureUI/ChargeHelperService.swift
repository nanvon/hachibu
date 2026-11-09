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
    /// 写入路由在后台线程读取，所以单独加锁保存。
    private nonisolated static let availability = Availability()

    /// `service` 为 nil 时（测试、渲染）始终未注册。
    public init(service: SMAppService? = SMAppService.daemon(plistName: ChargeHelper.daemonPlistName)) {
        self.service = service
        self.updatesAvailability = service != nil
        self.opensSystemSettings = service != nil
        refresh()
    }

    /// 测试注册、系统批准和取消时的状态变化，不触碰系统服务。
    init(registration: any ChargeHelperRegistration) {
        self.service = registration
        self.updatesAvailability = false
        self.opensSystemSettings = false
        refresh()
    }

    /// 给写入路由用的 helper 客户端；未批准时为 nil。可以在任意线程调用。
    public nonisolated static func readyClient() -> ChargeHelperClient? {
        availability.client
    }

    public func refresh() {
        let newState = ChargeHelperState(status: service?.status)
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
        case .requiresApproval: openLoginItems()
        case .enabled: break
        case .notRegistered, .unavailable:
            registrationError = failure ?? "SMAppService status: \(service.status.rawValue)"
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
    }

    /// 状态查询的超时。launchd 里有这个服务但启动失败时，连接不会立即报错，而是等到超时；
    /// 写入用的默认 8 秒对状态查询太长，设置页会长时间停在“正在检查”。
    static let statusTimeout: TimeInterval = 3

    /// 读取 helper 报告的状态，用于设置页、移除前检查和诊断导出。失败时为 nil。
    public func helperStatus() async -> ChargeHelperStatus? {
        guard Self.readyClient() != nil else { return nil }
        let client = ChargeHelperClient(timeout: Self.statusTimeout)
        return await Task.detached { try? client.status() }.value
    }

    /// 确认已允许的 helper 能连上。连不上时重新注册一次再试：在系统设置里打开开关时，
    /// smd 可能在密码验证完成前就尝试加载 helper（日志为 “Job is not allowed to bootstrap”），
    /// 验证完成后不会再加载，状态显示已允许，launchd 里却没有这个服务。重新注册会让 smd 再加载一次；
    /// helper 文件变过（ad-hoc 签名没有 Team ID，系统按文件校验和识别）时，重新注册后状态会变回需要允许。
    /// 最长约 3 + 1 + 3 + 1 + 3 秒。
    func connectedStatus(retryDelay: Duration = .seconds(1)) async -> ChargeHelperStatus? {
        if let status = await helperStatusRetrying(attempts: 2, delay: retryDelay) { return status }
        guard state == .enabled, !isBusy, !Task.isCancelled else { return nil }
        logger.info("Helper enabled but not reachable; registering again")
        register()
        guard state == .enabled, !Task.isCancelled else { return nil }
        try? await Task.sleep(for: retryDelay)
        return await helperStatus()
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
