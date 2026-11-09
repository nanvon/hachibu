import Foundation
import os

/// 特权 helper 的常量、XPC 接口和 App 侧客户端。规则见 docs/v1技术设计.md 21.3。
/// helper 只能修改充电上限：读取状态、设置 1–99 的目标、释放并恢复原值、续约，不开放任意 key、路径或命令。
public enum ChargeHelper {
    public static let appIdentifier = "io.github.nanvon.hachibu"
    /// helper 的签名标识符，与 launchd label 无关，各版本相同。
    public static let helperIdentifier = "io.github.nanvon.hachibu.helper"
    /// 0.1.10 及更早版本的固定 label。新版本不再注册它，只用来注销旧 helper。
    public static let legacyLabel = "io.github.nanvon.hachibu.helper"
    /// App Info.plist 里本版本 helper label 的 key，构建时由 `HACHIBU_HELPER_LABEL` 填入。
    public static let labelInfoKey = "HachibuHelperLabel"

    /// 本版本的 launchd label，也是 MachServices 名。每个版本不同：ad-hoc 签名没有 Team ID，
    /// 系统按 label 建后台项目记录并记下 helper 的 cdhash，之后不再更新，沿用旧 label 时升级后的 helper 会被拒绝启动。
    /// 只在 App 进程里有意义；helper 用 launchd 传入的 `XPC_SERVICE_NAME`。读不到（测试）时为 `legacyLabel`。
    public static let label: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: labelInfoKey) as? String
        return value.flatMap { isValidLabel($0) ? $0 : nil } ?? legacyLabel
    }()
    public static var machServiceName: String { label }
    /// `Contents/Library/LaunchDaemons/` 下本版本的文件名，`SMAppService.daemon(plistName:)` 用它注册。
    public static var daemonPlistName: String { plistName(for: label) }

    public static func plistName(for label: String) -> String { "\(label).plist" }

    /// `legacyLabel` 本身，或它加上 `.` 和版本后缀（字母、数字、`.`、`-`）。
    public static func isValidLabel(_ value: String) -> Bool {
        if value == legacyLabel { return true }
        let prefix = legacyLabel + "."
        guard value.hasPrefix(prefix), value.count <= 128 else { return false }
        let suffix = value.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    /// helper 可执行文件名，位于 `Contents/MacOS/`。
    public static let executableName = "HachibuHelper"
    /// 接口版本。改动 XPC 接口或行为时加一。
    public static let version = 1

    /// 超过这个时长没有续约，helper 按标记文件恢复系统原值。
    public static let leaseTimeout: TimeInterval = 300
    /// App 续约的间隔。
    public static let leaseRenewInterval: Duration = .seconds(30)
    /// helper 接受的目标范围。80% 及以上由 App 经 PowerUI 写入。
    public static let limitRange = 1...99

    /// helper 要求调用方满足的签名条件。ad-hoc 签名没有 Team ID，只能要求签名标识符，另外检查可执行文件位置。
    public static let callerRequirement = "identifier \"\(appIdentifier)\""
    /// App 要求 helper 满足的签名条件。
    public static let helperRequirement = "identifier \"\(helperIdentifier)\""
}

/// helper 的 XPC 接口。错误以英文消息返回，只用于日志。
@objc(HachibuChargeHelperProtocol)
public protocol ChargeHelperProtocol {
    /// 回复 `ChargeHelperStatus` 的 JSON。
    func status(reply: @escaping @Sendable (Data?) -> Void)
    /// 设置低于 80% 的目标（1–99）。第一次覆盖前保存原值。回复错误消息，成功为 nil。
    func setLimit(_ percent: Int, reply: @escaping @Sendable (String?) -> Void)
    /// 经 PowerUI 清掉登记，再按保存的原值恢复，成功后删除标记文件。
    func release(reply: @escaping @Sendable (String?) -> Void)
    /// 续约。`seconds` 为 0 表示退出后保留当前上限：不再超时恢复。
    func renewLease(seconds: Int, reply: @escaping @Sendable (String?) -> Void)
}

/// helper 报告的状态。
public struct ChargeHelperStatus: Sendable, Equatable, Codable {
    public var version: Int
    /// 本机系统版本已验证可以写入 PowerUIAgent 偏好。
    public var isSchemaSupported: Bool
    /// 偏好里的 `MCLFeatureState`，不存在时为 nil。
    public var featureState: Int?
    /// 偏好里的 `mclLimitValue`，不存在时为 nil。
    public var limitValue: Int?
    /// 偏好里的值格式不符，此时拒绝写入。
    public var isPreferenceValid: Bool
    /// 有保存原值的标记文件，即 helper 覆盖过上限且还没恢复。
    public var hasMarker: Bool
    /// 标记文件存在但格式不对：不恢复，需要用户在系统设置里手动检查。
    public var isMarkerCorrupt: Bool
    /// 选了退出后保留当前上限，不会超时恢复。
    public var keepsLimit: Bool
    /// 距续约超时的秒数，没有续约时为 nil。
    public var leaseRemainingSeconds: Int?

    public init(
        version: Int, isSchemaSupported: Bool, featureState: Int?, limitValue: Int?, isPreferenceValid: Bool,
        hasMarker: Bool, isMarkerCorrupt: Bool, keepsLimit: Bool, leaseRemainingSeconds: Int?
    ) {
        self.version = version
        self.isSchemaSupported = isSchemaSupported
        self.featureState = featureState
        self.limitValue = limitValue
        self.isPreferenceValid = isPreferenceValid
        self.hasMarker = hasMarker
        self.isMarkerCorrupt = isMarkerCorrupt
        self.keepsLimit = keepsLimit
        self.leaseRemainingSeconds = leaseRemainingSeconds
    }
}

/// PowerUIAgent 的偏好域和标记文件。helper 以 root 读写；格式校验也供测试使用。
public enum ManualChargeLimitPreferences {
    /// PowerUIAgent 的偏好域。root 进程用 `kCFPreferencesCurrentUser` 写入时落在 `/var/root/Library/Preferences/`。
    public static let domain = "com.apple.smartcharging.topoffprotection"
    public static let featureStateKey = "MCLFeatureState"
    public static let limitValueKey = "mclLimitValue"
    /// PowerUIAgent 收到后重新加载偏好。
    public static let reloadNotification = "com.apple.smartcharging.defaultschanged"
    /// 2026-11-09 在 macOS 27 上实测通过的系统大版本。其他版本只提供 80–100%。
    public static let verifiedMajorVersions: Set<Int> = [27]

    public static var isSchemaSupported: Bool {
        verifiedMajorVersions.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// 偏好里已有的值是否符合预期：`MCLFeatureState` 为 0 或 1，`mclLimitValue` 为 1–100 的整数，或者两者都不存在。
    public static func isValid(featureState: Any?, limitValue: Any?) -> Bool {
        func integer(_ value: Any?) -> Int?? {
            guard let value else { return .some(nil) }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
                  !CFNumberIsFloatType(number) else { return nil }
            return .some(number.intValue)
        }
        guard let state = integer(featureState), let limit = integer(limitValue) else { return false }
        if state == nil, limit == nil { return true }
        if let state, ![0, 1].contains(state) { return false }
        if let limit, !(1...100).contains(limit) { return false }
        return true
    }
}

/// helper 第一次覆盖前保存的原值，写在 root 所有的标记文件里。
public struct ChargeHelperMarker: Sendable, Equatable, Codable {
    public var featureState: Int?
    public var limitValue: Int?
    /// 选了退出后保留当前上限。
    public var keepsLimit: Bool

    public static let directory = URL(fileURLWithPath: "/Library/Application Support/io.github.nanvon.hachibu")
    public static let url = directory.appendingPathComponent("charge-limit-original.json")

    public init(featureState: Int?, limitValue: Int?, keepsLimit: Bool = false) {
        self.featureState = featureState
        self.limitValue = limitValue
        self.keepsLimit = keepsLimit
    }

    /// 标记文件内容是否可以用来恢复：开关为 0、1 或缺失，上限为 1–100 或缺失。
    public var isValid: Bool {
        (featureState.map { [0, 1].contains($0) } ?? true) && (limitValue.map { (1...100).contains($0) } ?? true)
    }

    /// 恢复时写回的上限：原来关闭或没有设置时为 nil（关闭）；原值低于 80 时按 80（PowerUI 只接受 80–100）。
    public var restoredLimit: Int? {
        guard featureState == 1, let limitValue, limitValue < 100 else { return nil }
        return max(limitValue, 80)
    }
}

/// App 与 helper 通信。每次调用新建连接，超时返回错误，不阻塞调用方超过 `timeout`。
public final class ChargeHelperClient: Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "ChargeControl")
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    public func status() throws -> ChargeHelperStatus {
        let data: Data? = try call { proxy, reply in proxy.status { reply($0) } }
        guard let data, let status = try? JSONDecoder().decode(ChargeHelperStatus.self, from: data) else {
            throw ChargeLimitWriteError(message: "Helper returned an unreadable status")
        }
        return status
    }

    public func setLimit(_ percent: Int) throws {
        try check(call { proxy, reply in proxy.setLimit(percent) { reply($0) } })
    }

    public func release() throws {
        try check(call { proxy, reply in proxy.release { reply($0) } })
    }

    public func renewLease(seconds: Int) throws {
        try check(call { proxy, reply in proxy.renewLease(seconds: seconds) { reply($0) } })
    }

    private func check(_ message: String?) throws {
        if let message { throw ChargeLimitWriteError(message: "Helper: \(message)") }
    }

    private func call<Value: Sendable>(
        _ body: (ChargeHelperProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) throws -> Value {
        let connection = NSXPCConnection(machServiceName: ChargeHelper.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ChargeHelperProtocol.self)
        connection.setCodeSigningRequirement(ChargeHelper.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let box = ReplyBox<Value>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            box.fail(error.localizedDescription)
        }
        guard let helper = proxy as? ChargeHelperProtocol else {
            throw ChargeLimitWriteError(message: "Helper proxy unavailable")
        }
        body(helper) { box.succeed($0) }
        guard box.semaphore.wait(timeout: .now() + timeout) == .success else {
            Self.logger.error("Helper call timed out")
            throw ChargeLimitWriteError(message: "Helper call timed out")
        }
        return try box.result()
    }

    private final class ReplyBox<Value: Sendable>: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: Result<Value, ChargeLimitWriteError>?

        func succeed(_ reply: Value) { finish(.success(reply)) }
        func fail(_ message: String) { finish(.failure(ChargeLimitWriteError(message: "Helper connection: \(message)"))) }

        private func finish(_ result: Result<Value, ChargeLimitWriteError>) {
            let first = lock.withLock { () -> Bool in
                guard value == nil else { return false }
                value = result
                return true
            }
            if first { semaphore.signal() }
        }

        func result() throws -> Value {
            try lock.withLock { value! }.get()
        }
    }
}
