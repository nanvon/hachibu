import Foundation
import ObjectiveC

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

/// 只调用读取方法，不调用任何 set / disable 方法。
/// 框架、类或方法缺失，或方法类型编码与本机实测（macOS 27.0.1）不一致时返回 nil，由调用方退回读取充电上限文件。
enum PowerUIClient {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"

    private static let expectedEncodings = [
        "initWithClientName:": "@24@0:8@16",
        "isMCLSupported": "B16@0:8",
        "getMCLLimitWithError:": "C24@0:8^@16",
        "isMCLCurrentlyEnabled:": "Q24@0:8^@16",
        "availableChargeLimitsWithError:": "@24@0:8^@16",
    ]

    private typealias BoolMethod = @convention(c) (AnyObject, Selector) -> Bool
    private typealias UInt8ErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias UInt64ErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt64
    private typealias ObjectErrorMethod = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?

    /// 进程内只创建一次，之后只在采样 actor 和诊断导出中读取。
    nonisolated(unsafe) private static let client: NSObject? = makeClient()

    static func read() -> PowerUIChargeLimit? {
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

    private static func makeClient() -> NSObject? {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              expectedEncodings.allSatisfy({ name, encoding in
                  class_getInstanceMethod(cls, NSSelectorFromString(name))
                      .flatMap(method_getTypeEncoding)
                      .map { String(cString: $0) } == encoding
              }),
              let instance = class_createInstance(cls, 0).map({ $0 as AnyObject })
        else { return nil }
        // init 方法会消耗接收者并返回 +1 的对象，先多保留一次，与 Swift 持有的引用相抵。
        _ = Unmanaged.passRetained(instance)
        return instance
            .perform(NSSelectorFromString("initWithClientName:"), with: "Hachibu")?
            .takeRetainedValue() as? NSObject
    }
}
