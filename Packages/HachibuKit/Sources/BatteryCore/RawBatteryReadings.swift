import Foundation

/// 一次完整读取得到的原始数据，未做任何解析。规则见 docs/v1技术设计.md 第 5、9 节。
public struct RawBatteryReadings: Sendable, Equatable, Codable {
    /// IOPS 电源列表中每个电源的描述字典。
    public var powerSources: [[String: RawValue]]
    /// IORegistry `AppleSmartBattery` 节点的全部属性。
    public var smartBattery: [String: RawValue]?
    /// IORegistry `AppleSmartBatteryPack` 节点的全部属性。
    public var smartBatteryPack: [String: RawValue]?
    /// `IOPSCopyExternalPowerAdapterDetails()` 的结果。
    public var adapterDetails: [String: RawValue]?
    /// 充电上限文件中 `policies` 字段解开后的 NSKeyedArchiver 归档结构。
    public var chargeLimitArchive: RawValue?
    public var lowPowerModeEnabled: Bool

    public init(
        powerSources: [[String: RawValue]],
        smartBattery: [String: RawValue]?,
        smartBatteryPack: [String: RawValue]?,
        adapterDetails: [String: RawValue]?,
        chargeLimitArchive: RawValue?,
        lowPowerModeEnabled: Bool
    ) {
        self.powerSources = powerSources
        self.smartBattery = smartBattery
        self.smartBatteryPack = smartBatteryPack
        self.adapterDetails = adapterDetails
        self.chargeLimitArchive = chargeLimitArchive
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case powerSources
        case smartBattery = "appleSmartBattery"
        case smartBatteryPack = "appleSmartBatteryPack"
        case adapterDetails = "externalPowerAdapterDetails"
        case chargeLimitArchive
        case lowPowerModeEnabled
    }

    /// 诊断导出用的脱敏副本，规则见 docs/v1技术设计.md 第 14 节。
    public func redacted() -> RawBatteryReadings {
        RawBatteryReadings(
            powerSources: powerSources.map { RawValue.redact($0) },
            smartBattery: smartBattery.map { RawValue.redact($0) },
            smartBatteryPack: smartBatteryPack.map { RawValue.redact($0) },
            adapterDetails: adapterDetails.map { RawValue.redact($0) },
            chargeLimitArchive: chargeLimitArchive?.redacted(extraKeys: ["token"]),
            lowPowerModeEnabled: lowPowerModeEnabled
        )
    }
}
