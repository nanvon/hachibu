import Foundation
import IOKit
import IOKit.ps

/// 硬件数据的读取来源。v2 增加 SMC 读取时实现新的来源，不改调用方。
public protocol BatteryDataSource: Sendable {
    /// 完整读取一次：IOPS、IORegistry 两个节点、充电器信息、充电上限文件、低电量模式。
    func read() -> RawBatteryReadings
}

/// 通过 IOKit 公开接口和充电上限文件读取。
public struct IOKitBatteryDataSource: BatteryDataSource {
    public init() {}

    public func read() -> RawBatteryReadings {
        RawBatteryReadings(
            powerSources: Self.powerSources(),
            smartBattery: Self.registryProperties(IOServiceMatching("AppleSmartBattery")),
            smartBatteryPack: Self.registryProperties(IOServiceNameMatching("AppleSmartBatteryPack")),
            adapterDetails: Self.adapterDetails(),
            chargeLimitArchive: ChargeLimitFile.readArchive(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func powerSources() -> [[String: RawValue]] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
        else { return [] }
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
