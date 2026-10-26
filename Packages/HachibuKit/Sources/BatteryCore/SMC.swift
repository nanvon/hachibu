import Foundation
import IOKit

/// 界面实时读数用到的 SMC key。类型和长度是本机实测值（MacBookPro18,1，macOS 27.0.1），
/// 不符时视为读不到。规则见 docs/v1技术设计.md 5.1 节。
public enum SMCKey: String, CaseIterable, Sendable {
    /// 是否在充电，1 / 0。
    case charging = "CHSC"
    /// 电池功率（mW），充电为正。
    case batteryPower = "B0AP"
    /// 电池电流（mA）。
    case batteryCurrent = "B0AC"
    /// 电池电压（mV）。
    case batteryVoltage = "B0AV"
    /// 输入功率（W）。
    case powerIn = "PDTR"
    /// 系统功率（W）。
    case systemPower = "PSTR"
    /// 输入电压（V）。
    case inputVoltage = "VD0R"
    /// 输入电流（A）。
    case inputCurrent = "ID0R"
    /// 电池温度（°C）。
    case temperature = "TB0T"
    /// 当前生效的充电上限，第一个字节为百分比，关闭时全 0。
    case chargeLimit = "CHLT"
    /// 与 `NotChargingReason` 对应，只写诊断导出。
    case notChargingReason = "CHNC"

    /// KeyInfo 应返回的类型和长度。
    public var expectedType: String {
        switch self {
        case .charging: "ui8 "
        case .batteryPower: "si32"
        case .batteryCurrent: "si16"
        case .batteryVoltage: "ui16"
        case .powerIn, .systemPower, .inputVoltage, .inputCurrent, .temperature: "flt "
        case .chargeLimit, .notChargingReason: "hex_"
        }
    }

    public var expectedSize: Int {
        switch self {
        case .charging: 1
        case .batteryCurrent, .batteryVoltage: 2
        case .chargeLimit: 3
        case .batteryPower, .powerIn, .systemPower, .inputVoltage, .inputCurrent, .temperature: 4
        case .notChargingReason: 8
        }
    }
}

/// 一次读取包含的 key。
public enum SMCReadScope: Sendable {
    /// 只读 `CHSC`，面板关闭时用来尽快发现充电状态变化。
    case charging
    /// 界面用到的全部 key。
    case display

    public var keys: [SMCKey] {
        switch self {
        case .charging: [.charging]
        case .display: SMCKey.allCases.filter { $0 != .notChargingReason }
        }
    }
}

/// 一个 key 的原始读数：KeyInfo 返回的类型和 Read 返回的字节，字节数即长度。
public struct SMCRawValue: Sendable, Equatable, Codable {
    /// 四个字符的类型，如 `flt `、`ui8 `。
    public var type: String
    public var bytes: [UInt8]

    public init(type: String, bytes: [UInt8]) {
        self.type = type
        self.bytes = bytes
    }

    /// 类型和长度与 key 的预期一致时返回字节，否则为 nil。
    func bytes(for key: SMCKey) -> [UInt8]? {
        type == key.expectedType && bytes.count == key.expectedSize ? bytes : nil
    }

    // 诊断导出里字节写成十六进制字符串。
    private enum CodingKeys: String, CodingKey { case type, bytes }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        let hex = try container.decode(String.self, forKey: .bytes)
        guard hex.count.isMultiple(of: 2) else {
            throw DecodingError.dataCorruptedError(forKey: .bytes, in: container, debugDescription: "Odd hex length")
        }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw DecodingError.dataCorruptedError(forKey: .bytes, in: container, debugDescription: "Invalid hex")
            }
            bytes.append(byte)
            index = next
        }
        self.bytes = bytes
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(bytes.map { String(format: "%02x", $0) }.joined(), forKey: .bytes)
    }
}

/// 解码后的 SMC 读数。读不到、类型或长度不符、不是有限数或超出合理范围的项为 nil，由调用方退回 IORegistry / IOPS。
/// 本机这些 key 都是小端序。规则见 docs/v1技术设计.md 5.1 节。
public struct SMCReadings: Sendable, Equatable {
    public var isCharging: Bool?
    /// 电池功率（mW），正数充电。
    public var batteryPowerMW: Int?
    public var batteryCurrentMA: Int?
    public var batteryVoltageMV: Int?
    public var powerInMW: Int?
    public var systemPowerMW: Int?
    public var inputVoltageMV: Int?
    public var inputCurrentMA: Int?
    public var temperatureCelsius: Double?
    /// 当前生效的充电上限（`CHLT`）。不参与显示。
    public var chargeLimit: ChargeLimitSetting?

    public init(
        isCharging: Bool? = nil,
        batteryPowerMW: Int? = nil,
        batteryCurrentMA: Int? = nil,
        batteryVoltageMV: Int? = nil,
        powerInMW: Int? = nil,
        systemPowerMW: Int? = nil,
        inputVoltageMV: Int? = nil,
        inputCurrentMA: Int? = nil,
        temperatureCelsius: Double? = nil,
        chargeLimit: ChargeLimitSetting? = nil
    ) {
        self.isCharging = isCharging
        self.batteryPowerMW = batteryPowerMW
        self.batteryCurrentMA = batteryCurrentMA
        self.batteryVoltageMV = batteryVoltageMV
        self.powerInMW = powerInMW
        self.systemPowerMW = systemPowerMW
        self.inputVoltageMV = inputVoltageMV
        self.inputCurrentMA = inputCurrentMA
        self.temperatureCelsius = temperatureCelsius
        self.chargeLimit = chargeLimit
    }

    public init(_ values: [SMCKey: SMCRawValue]) {
        func bytes(_ key: SMCKey) -> [UInt8]? { values[key]?.bytes(for: key) }

        self.init(
            isCharging: bytes(.charging).flatMap { bytes in
                switch bytes[0] {
                case 0: false
                case 1: true
                default: nil
                }
            },
            batteryPowerMW: bytes(.batteryPower).map(Self.int32).flatMap { Self.within($0, -250_000...250_000) },
            batteryCurrentMA: bytes(.batteryCurrent).map(Self.int16).flatMap { Self.within($0, -20_000...20_000) },
            batteryVoltageMV: bytes(.batteryVoltage).map(Self.uint16).flatMap { Self.within($0, 5_000...20_000) },
            powerInMW: Self.scaled(bytes(.powerIn), by: 1000, range: 0...300),
            systemPowerMW: Self.scaled(bytes(.systemPower), by: 1000, range: 0...300),
            inputVoltageMV: Self.scaled(bytes(.inputVoltage), by: 1000, range: 0...60),
            inputCurrentMA: Self.scaled(bytes(.inputCurrent), by: 1000, range: 0...10),
            // 与 Pack 节点温度（0.01 °C）取同样的精度，去掉单精度浮点的尾数。
            temperatureCelsius: bytes(.temperature).map(Self.float).flatMap {
                $0.isFinite && (-20...100).contains($0) ? (Double($0) * 100).rounded() / 100 : nil
            },
            chargeLimit: bytes(.chargeLimit).flatMap { bytes in
                if bytes.allSatisfy({ $0 == 0 }) { return .off }
                return (50...100).contains(Int(bytes[0])) ? .on(percent: Int(bytes[0])) : nil
            }
        )
    }

    // MARK: 小端序解码

    static func int16(_ bytes: [UInt8]) -> Int {
        Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
    }

    static func uint16(_ bytes: [UInt8]) -> Int {
        Int(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
    }

    static func int32(_ bytes: [UInt8]) -> Int {
        Int(Int32(bitPattern: uint32(bytes)))
    }

    static func float(_ bytes: [UInt8]) -> Float {
        Float(bitPattern: uint32(bytes))
    }

    private static func uint32(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    private static func within(_ value: Int, _ range: ClosedRange<Int>) -> Int? {
        range.contains(value) ? value : nil
    }

    /// 浮点读数在合理范围内时乘以 `factor` 后四舍五入取整。
    private static func scaled(_ bytes: [UInt8]?, by factor: Float, range: ClosedRange<Float>) -> Int? {
        guard let value = bytes.map(float), value.isFinite, range.contains(value) else { return nil }
        return Int((value * factor).rounded())
    }
}

extension BatterySnapshot {
    /// 用 SMC 读数替换对应字段，读不到的字段保留 IOPS / IORegistry 的原值。不做配平。
    public func applying(_ smc: SMCReadings) -> BatterySnapshot {
        var snapshot = self
        snapshot.isCharging = smc.isCharging ?? isCharging
        snapshot.batteryPowerMW = smc.batteryPowerMW ?? batteryPowerMW
        snapshot.amperageMA = smc.batteryCurrentMA ?? amperageMA
        snapshot.voltageMV = smc.batteryVoltageMV ?? voltageMV
        snapshot.powerInMW = smc.powerInMW ?? powerInMW
        snapshot.systemLoadMW = smc.systemPowerMW ?? systemLoadMW
        snapshot.inputVoltageMV = smc.inputVoltageMV ?? inputVoltageMV
        snapshot.inputCurrentMA = smc.inputCurrentMA ?? inputCurrentMA
        snapshot.temperatureCelsius = smc.temperatureCelsius ?? temperatureCelsius
        return snapshot
    }
}

/// AppleSMC user client 的只读连接，普通用户权限可用。只发 KeyInfo（9）和 Read（5）两条命令，没有写入代码。
/// 调用在锁内串行执行，单次读取为微秒级，可以在任意线程调用，不经过采样 actor。
public final class SMCReader: @unchecked Sendable {
    public static let shared = SMCReader()

    private struct KeyInfo {
        var type: String
        var size: Int
    }

    /// `IOConnectCallStructMethod` 的参数结构体（80 字节）中各字段的偏移，与 C 结构体 `SMCParamStruct` 的布局一致。
    private enum Layout {
        static let size = 80
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let bytes = 48
        static let byteCount = 32
    }

    private enum Command: UInt8 {
        case read = 5
        case keyInfo = 9
    }

    private enum CallResult {
        case success([UInt8])
        /// SMC 返回非 0 结果，如 key 不存在。
        case smcError
        /// IOKit 调用失败，如被拒绝或连接失效。
        case ioError
    }

    private enum ReadResult {
        case value(SMCRawValue)
        /// key 不存在、类型不符或 SMC 返回错误。
        case unavailable
        case ioError
    }

    private static let selector: UInt32 = 2
    /// 打开连接失败后，过这么久才重试。
    private static let reopenDelay: TimeInterval = 60

    private let lock = NSLock()
    private var connection: io_connect_t = IO_OBJECT_NULL
    private var lastOpenFailure: Date?
    /// 本次连接内 KeyInfo 的结果。nil 表示这个 key 不存在、被拒绝或类型不符。
    private var keyInfoCache: [SMCKey: KeyInfo?] = [:]

    init() {}

    deinit {
        if connection != IO_OBJECT_NULL { IOServiceClose(connection) }
    }

    /// 解码后的读数。打不开连接时返回 nil。
    public func read(_ scope: SMCReadScope) -> SMCReadings? {
        readRaw(scope.keys).map(SMCReadings.init)
    }

    /// 读取原始值。类型和长度与预期不符或读取失败的 key 不在结果中；打不开连接时返回 nil。
    public func readRaw(_ keys: [SMCKey]) -> [SMCKey: SMCRawValue]? {
        lock.withLock {
            guard openIfNeeded() else { return nil }
            var values: [SMCKey: SMCRawValue] = [:]
            var ioErrors = 0
            for key in keys {
                switch readLocked(key) {
                case .value(let value): values[key] = value
                case .unavailable: break
                case .ioError: ioErrors += 1
                }
            }
            // 全部 key 都是 IOKit 错误时连接可能已失效，下次重新打开。
            if !keys.isEmpty, ioErrors == keys.count { closeLocked() }
            return values
        }
    }

    private func readLocked(_ key: SMCKey) -> ReadResult {
        let info: KeyInfo
        if let cached = keyInfoCache[key] {
            guard let cached else { return .unavailable }
            info = cached
        } else {
            switch call(.keyInfo, key: key) {
            case .success(let output):
                let fetched = KeyInfo(
                    type: Self.fourCharacterCode(Self.uint32(output, at: Layout.dataType)),
                    size: Int(Self.uint32(output, at: Layout.dataSize))
                )
                // 类型或长度不符时不发 Read，按读不到处理。
                let matches = fetched.type == key.expectedType && fetched.size == key.expectedSize
                keyInfoCache[key] = matches ? fetched : .some(nil)
                guard matches else { return .unavailable }
                info = fetched
            case .smcError:
                keyInfoCache[key] = .some(nil)
                return .unavailable
            case .ioError:
                // 被拒绝的 key（如 kIOReturnNotPrivileged）记为读不到，不重复查询。
                keyInfoCache[key] = .some(nil)
                return .ioError
            }
        }

        switch call(.read, key: key, dataSize: info.size) {
        case .success(let output):
            let bytes = Array(output[Layout.bytes..<(Layout.bytes + info.size)])
            return .value(SMCRawValue(type: info.type, bytes: bytes))
        case .smcError:
            return .unavailable
        case .ioError:
            closeLocked()
            return .ioError
        }
    }

    private func call(_ command: Command, key: SMCKey, dataSize: Int = 0) -> CallResult {
        var input = [UInt8](repeating: 0, count: Layout.size)
        Self.store(Self.fourCharacterCode(key.rawValue), in: &input, at: Layout.key)
        Self.store(UInt32(dataSize), in: &input, at: Layout.dataSize)
        input[Layout.command] = command.rawValue
        var output = [UInt8](repeating: 0, count: Layout.size)
        var outputSize = Layout.size
        let status = input.withUnsafeBytes { inputBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                IOConnectCallStructMethod(
                    connection, Self.selector,
                    inputBuffer.baseAddress, Layout.size,
                    outputBuffer.baseAddress, &outputSize
                )
            }
        }
        guard status == kIOReturnSuccess else { return .ioError }
        guard output[Layout.result] == 0 else { return .smcError }
        return .success(output)
    }

    private func openIfNeeded() -> Bool {
        guard connection == IO_OBJECT_NULL else { return true }
        if let lastOpenFailure, Date().timeIntervalSince(lastOpenFailure) < Self.reopenDelay { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else {
            lastOpenFailure = Date()
            return false
        }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &opened) == kIOReturnSuccess else {
            lastOpenFailure = Date()
            return false
        }
        connection = opened
        lastOpenFailure = nil
        return true
    }

    private func closeLocked() {
        if connection != IO_OBJECT_NULL { IOServiceClose(connection) }
        connection = IO_OBJECT_NULL
        keyInfoCache = [:]
    }

    // MARK: 参数结构体按本机字节序（arm64 为小端）读写

    private static func fourCharacterCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, as: UTF8.self)
    }

    private static func store(_ value: UInt32, in buffer: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { buffer.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private static func uint32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer[offset..<(offset + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}
