import Foundation
import ObjectiveC
import os

/// 私有框架 PowerUI 中 `PowerUISmartChargeClient` 的只读结果，对应“系统设置 → 电池 → 充电上限”。
/// 规则见 docs/v1技术设计.md 第 6 节。
public struct PowerUIChargeLimit: Sendable, Equatable, Codable {
    /// `isMCLSupported`：本机系统和机型是否支持充电上限。
    public var isSupported: Bool
    /// `isMCLCurrentlyEnabled:`，出错时为 nil。
    public var isEnabled: Bool?
    /// `getMCLLimitWithError:`（%），出错时为 nil。
    public var limit: Int?
    /// `availableChargeLimitsWithError:`（%），出错时为 nil。
    public var availableLimits: [Int]?

    public init(isSupported: Bool, isEnabled: Bool? = nil, limit: Int? = nil, availableLimits: [Int]? = nil) {
        self.isSupported = isSupported
        self.isEnabled = isEnabled
        self.limit = limit
        self.availableLimits = availableLimits
    }
}

/// 读取：框架、类或方法缺失，或方法类型编码与本机实测（macOS 27.0.1）不一致时返回 nil，由调用方退回读取充电上限文件。
/// 写入：只调用 `setMCLLimit:error:`、`enableMCL:`、`disableMCL:`，类型编码不一致时不提供写入，读取不受影响。
enum PowerUIClient {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"

    private static let expectedEncodings = [
        "initWithClientName:": "@24@0:8@16",
        "isMCLSupported": "B16@0:8",
        "getMCLLimitWithError:": "C24@0:8^@16",
        "isMCLCurrentlyEnabled:": "Q24@0:8^@16",
        "availableChargeLimitsWithError:": "@24@0:8^@16",
    ]

    /// 写入方法，类型编码为 2026-10-24 本机实验时的值，见 docs/v2充电控制技术调研.md。
    private static let writeEncodings = [
        "setMCLLimit:error:": "B28@0:8C16^@20",
        "enableMCL:": "B24@0:8^@16",
        "disableMCL:": "B24@0:8^@16",
    ]

    private typealias BoolMethod = @convention(c) (AnyObject, Selector) -> Bool
    private typealias UInt8ErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias UInt64ErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt64
    private typealias ObjectErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
    private typealias BoolErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    private typealias SetLimitMethod = @convention(c) (AnyObject, Selector, UInt8, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

    private static let operations = PowerUIOperationQueue()
    private static let writeReadback = WriteReadback()
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "PowerUI")

    /// 初始化和所有方法调用均在 operations 的专用队列上执行。
    nonisolated(unsafe) private static let client: NSObject? = makeClient()
    private static let clientClass: AnyClass? = loadClientClass()

    /// 读取可用，且写入方法的类型编码与实测一致。
    static let canWrite: Bool = clientClass.map { cls in
        writeEncodings.allSatisfy { name, encoding in
            class_getInstanceMethod(cls, NSSelectorFromString(name))
                .flatMap(method_getTypeEncoding)
                .map { String(cString: $0) } == encoding
        }
    } ?? false

    /// 写入一次。方法返回 false 或给出错误时抛出 `ChargeLimitWriteError`。
    static func write(_ change: ChargeLimitChange) throws {
        try operations.run(timeout: .seconds(5)) {
            try writeCurrent(change)
            // 与写入在同一队列中读回，不用延迟更新的文件判断成功。
            let value = readCurrent()
            guard change.isApplied(to: ChargeLimitSetting.resolve(powerUI: value, archive: nil)), let value else {
                throw ChargeLimitWriteError(message: "PowerUI read back does not match requested limit")
            }
            writeReadback.store(value)
        }
    }

    private static func writeCurrent(_ change: ChargeLimitChange) throws {
        guard canWrite, let client else { throw ChargeLimitWriteError(message: "PowerUI write methods unavailable") }
        var error: NSError?
        let succeeded: Bool
        switch change {
        case .enable, .disable:
            let name = change == .enable ? "enableMCL:" : "disableMCL:"
            succeeded = unsafeBitCast(
                client.method(for: NSSelectorFromString(name)), to: BoolErrorMethod.self
            )(client, NSSelectorFromString(name), &error)
        case .limit(let percent):
            guard let value = UInt8(exactly: percent), (50...100).contains(percent) else {
                throw ChargeLimitWriteError(message: "Limit out of range: \(percent)")
            }
            succeeded = unsafeBitCast(
                client.method(for: NSSelectorFromString("setMCLLimit:error:")), to: SetLimitMethod.self
            )(client, NSSelectorFromString("setMCLLimit:error:"), value, &error)
        }
        if let error {
            throw ChargeLimitWriteError(message: "\(error.domain) \(error.code): \(error.localizedDescription)")
        }
        guard succeeded else { throw ChargeLimitWriteError(message: "PowerUI returned false") }
    }

    static func read() -> PowerUIChargeLimit? {
        // 写入后的立即刷新复用同一次操作已验证的结果，避免与周期读取争用队列。
        if let value = writeReadback.recentValue() { return value }
        // 慢调用继续占用专用队列，超时后走文件回退；不累积后续请求。
        do {
            return try operations.run(timeout: .milliseconds(500)) { readCurrent() }
        } catch {
            if error as? PowerUIOperationQueue.Failure == .timedOut {
                logger.error("PowerUI read timed out; using file fallback")
            }
            return nil
        }
    }

    private final class WriteReadback: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (reading: PowerUIChargeLimit, date: Date)?

        func store(_ reading: PowerUIChargeLimit) {
            lock.withLock { value = (reading, Date()) }
        }

        func recentValue() -> PowerUIChargeLimit? {
            lock.withLock {
                guard let value, Date().timeIntervalSince(value.date) < 1 else { return nil }
                return value.reading
            }
        }
    }

    private static func readCurrent() -> PowerUIChargeLimit? {
        guard let client else { return nil }
        let isSupported = unsafeBitCast(
            client.method(for: NSSelectorFromString("isMCLSupported")), to: BoolMethod.self
        )(client, NSSelectorFromString("isMCLSupported"))
        guard isSupported else { return PowerUIChargeLimit(isSupported: false) }

        var error: NSError?
        let enabled = unsafeBitCast(
            client.method(for: NSSelectorFromString("isMCLCurrentlyEnabled:")), to: UInt64ErrorMethod.self
        )(client, NSSelectorFromString("isMCLCurrentlyEnabled:"), &error)
        let isEnabled = error == nil ? enabled != 0 : nil

        error = nil
        let limit = unsafeBitCast(
            client.method(for: NSSelectorFromString("getMCLLimitWithError:")), to: UInt8ErrorMethod.self
        )(client, NSSelectorFromString("getMCLLimitWithError:"), &error)
        let limitValue = error == nil ? Int(limit) : nil

        error = nil
        let available = unsafeBitCast(
            client.method(for: NSSelectorFromString("availableChargeLimitsWithError:")), to: ObjectErrorMethod.self
        )(client, NSSelectorFromString("availableChargeLimitsWithError:"), &error)?.takeUnretainedValue()
        let availableLimits = error == nil ? (available as? [NSNumber])?.map(\.intValue) : nil

        return PowerUIChargeLimit(
            isSupported: true, isEnabled: isEnabled, limit: limitValue, availableLimits: availableLimits
        )
    }

    private static func loadClientClass() -> AnyClass? {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              expectedEncodings.allSatisfy({ name, encoding in
                  class_getInstanceMethod(cls, NSSelectorFromString(name))
                      .flatMap(method_getTypeEncoding)
                      .map { String(cString: $0) } == encoding
              })
        else { return nil }
        return cls
    }

    private static func makeClient() -> NSObject? {
        guard let cls = clientClass,
              let instance = class_createInstance(cls, 0).map({ $0 as AnyObject })
        else { return nil }
        // init 方法会消耗接收者并返回 +1 的对象，先多保留一次，与 Swift 持有的引用相抵。
        _ = Unmanaged.passRetained(instance)
        return instance
            .perform(NSSelectorFromString("initWithClientName:"), with: "Hachibu")?
            .takeRetainedValue() as? NSObject
    }
}

/// 私有同步接口无法被 Task 取消。超时只结束等待，原调用结束前拒绝新请求，避免线程或请求堆积。
final class PowerUIOperationQueue: @unchecked Sendable {
    enum Failure: Error, Equatable { case busy, timedOut }

    private let queue = DispatchQueue(label: "Hachibu.PowerUI", qos: .utility)
    private let lock = NSLock()
    private var isRunning = false

    func run<Value: Sendable>(
        timeout: DispatchTimeInterval,
        _ operation: @escaping @Sendable () throws -> Value
    ) throws -> Value {
        let started = lock.withLock {
            guard !isRunning else { return false }
            isRunning = true
            return true
        }
        guard started else { throw Failure.busy }
        let result = OperationResult<Value>()
        queue.async { [self] in
            let value = autoreleasepool { Result(catching: operation) }
            lock.withLock { isRunning = false }
            result.complete(value)
        }
        guard result.finished.wait(timeout: .now() + timeout) == .success else { throw Failure.timedOut }
        return try result.value().get()
    }

    private final class OperationResult<Value: Sendable>: @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<Value, any Error>?

        func complete(_ value: Result<Value, any Error>) {
            lock.withLock { result = value }
            finished.signal()
        }

        func value() -> Result<Value, any Error> {
            lock.withLock { result! }
        }
    }
}
