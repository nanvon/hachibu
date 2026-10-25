import Foundation
import IOKit
import IOKit.ps

/// 硬件数据的读取来源。v2 增加 SMC 读取时实现新的来源，不改调用方。
public protocol BatteryDataSource: Sendable {
    /// 完整读取一次：IOPS、IORegistry 两个节点、充电器信息、充电上限（PowerUI 和文件）、低电量模式。
    func read() -> RawBatteryReadings
}

/// 通过 IOKit 公开接口、PowerUI 只读接口和充电上限文件读取。
public struct IOKitBatteryDataSource: BatteryDataSource {
    public init() {}

    public func read() -> RawBatteryReadings {
        RawBatteryReadings(
            powerSources: Self.powerSources() ?? [],
            smartBattery: Self.registryProperties(IOServiceMatching("AppleSmartBattery")),
            smartBatteryPack: Self.registryProperties(IOServiceNameMatching("AppleSmartBatteryPack")),
            adapterDetails: Self.adapterDetails(),
            chargeLimitArchive: ChargeLimitFile.readArchive(),
            powerUIChargeLimit: PowerUIClient.read(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// 菜单栏和面板的快速状态读取；不访问 IORegistry、PowerUI 或充电上限文件。
    /// 读取失败返回 nil；读取成功但没有内置电池时返回 .noBattery。
    public static func readPowerSource() -> BatteryReading? {
        guard let sources = powerSources() else { return nil }
        return BatteryReading(RawBatteryReadings(
            powerSources: sources, smartBattery: nil, smartBatteryPack: nil,
            adapterDetails: nil, chargeLimitArchive: nil,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        ))
    }

    private static func powerSources() -> [[String: RawValue]]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        else { return nil }
        return (list as [CFTypeRef]).compactMap { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() else {
                return nil
            }
            return RawValue(propertyList: description)?.dictionaryValue
        }
    }

    private static func registryProperties(_ matching: CFMutableDictionary) -> [String: RawValue]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue()
        else { return nil }
        return RawValue(propertyList: dictionary)?.dictionaryValue
    }

    private static func adapterDetails() -> [String: RawValue]? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() else { return nil }
        return RawValue(propertyList: details)?.dictionaryValue
    }
}
