// Hachibu 的特权 helper，以 root 运行，只能修改充电上限。规则见 docs/v1技术设计.md 21.3。
// 由 App 通过 SMAppService.daemon 注册，launchd 按 MachServices 按需启动，开机时也启动一次（RunAtLoad），
// 用来在 App 崩溃或被强制退出后按续约超时恢复系统原值。
import BatteryCore
import Darwin
import Foundation
import notify
import os

private let logger = Logger(subsystem: ChargeHelper.helperIdentifier, category: "ChargeControl")

final class Daemon: NSObject, NSXPCListenerDelegate, ChargeHelperProtocol, @unchecked Sendable {
    /// 所有状态只在这个队列上读写。
    private let queue = DispatchQueue(label: "io.github.nanvon.hachibu.helper")
    private var timer: DispatchSourceTimer?
    private var leaseDeadline: Date?
    private var lastActivity = Date()
    private var connectionCount = 0
    /// 最近一次释放时标记文件格式不对，没有恢复原值。下一次成功设置后清除。
    private var skippedCorruptRestore = false
    /// 允许连接的 App 主程序路径：helper 所在 App 包的 `Contents/MacOS/Hachibu`。
    private let appExecutablePath: String?
    /// 启动时自己的可执行文件。App 升级后文件被替换，新版本用新的 label 注册自己的 helper。
    private let ownExecutablePath: String?
    private let ownFileID: FileID?

    /// 没有标记文件、没有连接且空闲这么久后退出，下次由 launchd 按需启动。
    private static let idleExitInterval: TimeInterval = 120
    private static let tickInterval: DispatchTimeInterval = .seconds(15)

    override init() {
        ownExecutablePath = Self.executablePath(pid: getpid())
        ownFileID = ownExecutablePath.flatMap(FileID.init(path:))
        let own = ownExecutablePath.map(URL.init(fileURLWithPath:))
        // .../Hachibu.app/Contents/MacOS/HachibuHelper → .../Hachibu.app/Contents/MacOS/Hachibu
        appExecutablePath = own?.deletingLastPathComponent().appendingPathComponent("Hachibu").path
        super.init()
    }

    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    func start() {
        queue.sync {
            // 开机或崩溃后重新启动：有未恢复的覆盖时给 App 一个续约周期，超时再恢复。
            if case .valid(let marker)? = readMarker(), !marker.keepsLimit {
                leaseDeadline = Date().addingTimeInterval(ChargeHelper.leaseTimeout)
                logger.info("Started with marker; lease deadline set")
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let callerPath = Self.executablePath(pid: connection.processIdentifier)
        guard let appExecutablePath, let callerPath,
              URL(fileURLWithPath: callerPath).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: appExecutablePath).resolvingSymlinksInPath().path
        else {
            logger.error("Rejected caller at \(callerPath ?? "unknown", privacy: .public)")
            return false
        }
        connection.setCodeSigningRequirement(ChargeHelper.callerRequirement)
        connection.exportedInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.connectionCount -= 1
                self.lastActivity = Date()
            }
        }
        queue.sync { connectionCount += 1 }
        connection.resume()
        return true
    }

    func status(reply: @escaping @Sendable (Data?) -> Void) {
        let status = queue.sync { () -> ChargeHelperStatus in
            lastActivity = Date()
            let values = Self.readPreferences()
            let marker = readMarker()
            return ChargeHelperStatus(
                version: ChargeHelper.version,
                isSchemaSupported: ManualChargeLimitPreferences.isSchemaSupported,
                featureState: (values.featureState as? NSNumber)?.intValue,
                limitValue: (values.limitValue as? NSNumber)?.intValue,
                isPreferenceValid: ManualChargeLimitPreferences.isValid(
                    featureState: values.featureState, limitValue: values.limitValue
                ),
                hasMarker: marker != nil,
                isMarkerCorrupt: skippedCorruptRestore || marker == .corrupt,
                keepsLimit: { if case .valid(let m)? = marker { m.keepsLimit } else { false } }(),
                leaseRemainingSeconds: leaseDeadline.map { max(Int($0.timeIntervalSinceNow), 0) }
            )
        }
        reply(try? JSONEncoder().encode(status))
    }

    func setLimit(_ percent: Int, reply: @escaping @Sendable (String?) -> Void) {
        reply(queue.sync { performSetLimit(percent) })
    }

    func release(reply: @escaping @Sendable (String?) -> Void) {
        reply(queue.sync { performRelease(reason: "request") })
    }

    func renewLease(seconds: Int, reply: @escaping @Sendable (String?) -> Void) {
        reply(queue.sync { () -> String? in
            lastActivity = Date()
            guard case .valid(var marker)? = readMarker() else {
                leaseDeadline = nil
                return nil
            }
            let keeps = seconds == 0
            if marker.keepsLimit != keeps {
                marker.keepsLimit = keeps
                if let error = writeMarker(marker) { return error }
                logger.info("Keeps limit after quit: \(keeps, privacy: .public)")
            }
            leaseDeadline = keeps ? nil : Date().addingTimeInterval(TimeInterval(min(max(seconds, 60), 900)))
            return nil
        })
    }

    // MARK: - 操作

    private func performSetLimit(_ percent: Int) -> String? {
        lastActivity = Date()
        guard ChargeHelper.limitRange.contains(percent) else { return "Limit out of range: \(percent)" }
        guard ManualChargeLimitPreferences.isSchemaSupported else { return "Unverified macOS version" }
        let values = Self.readPreferences()
        guard ManualChargeLimitPreferences.isValid(featureState: values.featureState, limitValue: values.limitValue) else {
            logger.error("Unrecognized PowerUIAgent preferences; refusing to write")
            return "Unrecognized preferences"
        }
        switch readMarker() {
        case .corrupt?:
            logger.error("Marker is corrupt; refusing to write")
            return "Marker corrupt"
        case nil:
            // 第一次覆盖前保存原值。
            let marker = ChargeHelperMarker(
                featureState: (values.featureState as? NSNumber)?.intValue,
                limitValue: (values.limitValue as? NSNumber)?.intValue
            )
            if let error = writeMarker(marker) { return error }
            logger.info("Saved original state \(marker.featureState ?? -1, privacy: .public) limit \(marker.limitValue ?? -1, privacy: .public)")
        case .valid?:
            break
        }
        guard Self.writePreferences(featureState: 1, limitValue: percent) else { return "Failed to write preferences" }
        guard notify_post(ManualChargeLimitPreferences.reloadNotification) == UInt32(NOTIFY_STATUS_OK) else {
            return "Failed to post reload notification"
        }
        skippedCorruptRestore = false
        if case .valid(let marker)? = readMarker(), marker.keepsLimit {
            leaseDeadline = nil
        } else {
            leaseDeadline = Date().addingTimeInterval(ChargeHelper.leaseTimeout)
        }
        logger.info("Set limit \(percent, privacy: .public)")
        return nil
    }

    /// 经 PowerUI 清掉登记：Agent 读回为关闭时会忽略 `disableMCL:`，先开启再关闭。然后按原值恢复。
    private func performRelease(reason: String) -> String? {
        lastActivity = Date()
        let marker = readMarker()
        guard marker != .corrupt else {
            skippedCorruptRestore = true
            logger.error("Marker is corrupt; refusing to guess the original limit")
            return "Marker corrupt; check the charge limit in System Settings"
        }
        guard let writer = PowerUIChargeLimitWriter() else { return "PowerUI unavailable" }
        do {
            if PowerUIChargeLimitWriter.currentSetting() == .off {
                try writer.write(.enable)
            }
            try writer.write(.disable)
            switch marker {
            case .valid(let original)?:
                if let limit = original.restoredLimit {
                    try writer.write(.enable)
                    try writer.write(.limit(limit))
                } else {
                    // 原来关闭：保持关闭，把偏好里的目标值写回原样，以免以后开启时恢复成低于 80% 的值。
                    _ = Self.writePreferences(featureState: nil, limitValue: original.limitValue, keepsFeatureState: true)
                    _ = notify_post(ManualChargeLimitPreferences.reloadNotification)
                }
                skippedCorruptRestore = false
            case .corrupt?:
                logger.error("Marker is corrupt; original limit not restored")
                skippedCorruptRestore = true
            case nil:
                break
            }
        } catch {
            logger.error("Release failed (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
            return "Release failed: \(String(describing: error))"
        }
        if marker != nil {
            do { try FileManager.default.removeItem(at: ChargeHelperMarker.url) }
            catch {
                logger.error("Could not remove restored marker: \(String(describing: error), privacy: .public)")
                return "Could not remove restored marker"
            }
        }
        leaseDeadline = nil
        logger.info("Released limit (\(reason, privacy: .public))")
        return nil
    }

    private func tick() {
        // 可执行文件被替换（App 已升级）：直接退出，不释放、不删标记文件。新版本的 helper 用新的 label 运行，
        // 允许后按标记续约或恢复；旧进程留着会在续约超时后把上限恢复成原值，覆盖新 helper 的写入。
        if let ownExecutablePath, let ownFileID, FileID(path: ownExecutablePath) != ownFileID {
            logger.info("Executable replaced; exiting without release")
            exit(0)
        }
        let marker = readMarker()
        if case .valid(let marker)? = marker, !marker.keepsLimit {
            guard let deadline = leaseDeadline else {
                leaseDeadline = Date().addingTimeInterval(ChargeHelper.leaseTimeout)
                return
            }
            if Date() > deadline {
                logger.error("Lease expired; restoring original limit")
                _ = performRelease(reason: "lease expired")
            }
            return
        }
        if marker == nil, connectionCount <= 0, Date().timeIntervalSince(lastActivity) > Self.idleExitInterval {
            logger.info("Idle; exiting")
            exit(0)
        }
    }

    // MARK: - 偏好和标记文件

    private enum MarkerState: Equatable {
        case valid(ChargeHelperMarker)
        case corrupt
    }

    private func readMarker() -> MarkerState? {
        guard let data = try? Data(contentsOf: ChargeHelperMarker.url) else { return nil }
        guard let marker = try? JSONDecoder().decode(ChargeHelperMarker.self, from: data), marker.isValid else {
            return .corrupt
        }
        return .valid(marker)
    }

    private func writeMarker(_ marker: ChargeHelperMarker) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: ChargeHelperMarker.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            try JSONEncoder().encode(marker).write(to: ChargeHelperMarker.url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ChargeHelperMarker.url.path)
            return nil
        } catch {
            logger.error("Failed to write marker: \(String(describing: error), privacy: .public)")
            return "Failed to save original limit"
        }
    }

    private static var domain: CFString { ManualChargeLimitPreferences.domain as CFString }

    private static func readPreferences() -> (featureState: Any?, limitValue: Any?) {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        func value(_ key: String) -> Any? {
            CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        return (value(ManualChargeLimitPreferences.featureStateKey), value(ManualChargeLimitPreferences.limitValueKey))
    }

    /// root 进程以 `kCFPreferencesCurrentUser` 写入，落在 PowerUIAgent 读取的 `/var/root/Library/Preferences/`。
    /// `limitValue` 为 nil 时删除这个 key。
    private static func writePreferences(featureState: Int?, limitValue: Int?, keepsFeatureState: Bool = false) -> Bool {
        if !keepsFeatureState {
            CFPreferencesSetValue(
                ManualChargeLimitPreferences.featureStateKey as CFString, featureState.map { NSNumber(value: $0) },
                domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
            )
        }
        CFPreferencesSetValue(
            ManualChargeLimitPreferences.limitValueKey as CFString, limitValue.map { NSNumber(value: $0) },
            domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

guard geteuid() == 0 else {
    logger.error("Helper must run as root")
    exit(1)
}

// launchd 按 plist 的 Label 设置 XPC_SERVICE_NAME，MachServices 与 Label 同名。label 随版本变化，见 docs/v1技术设计.md 21.3。
let serviceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
    .flatMap { ChargeHelper.isValidLabel($0) ? $0 : nil } ?? ChargeHelper.legacyLabel
let daemon = Daemon()
let listener = NSXPCListener(machServiceName: serviceName)
listener.delegate = daemon
daemon.start()
listener.resume()
logger.info("Helper \(ChargeHelper.version, privacy: .public) started as \(serviceName, privacy: .public)")
dispatchMain()
