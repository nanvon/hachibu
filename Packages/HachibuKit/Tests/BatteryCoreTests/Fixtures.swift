import Foundation
@testable import BatteryCore

/// 读取 `Tests/Fixtures` 下的诊断导出文件。
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// MacBookPro18,1、macOS 27.0.1、140W 充电器、接电未充电、系统充电上限 80%。
    static let acNotCharging = "ac-not-charging_MacBookPro18-1_macOS27.0.1"
    /// 同一台机器，使用电池，AlDente 已退出。
    static let onBattery = "on-battery_MacBookPro18-1_macOS27.0.1"
    /// 同一台机器，140W 充电器、充电中、系统充电上限 80%，AlDente 已退出。
    static let charging = "charging_MacBookPro18-1_macOS27.0.1"

    static let all = [acNotCharging, onBattery, charging]

    static func report(_ name: String) throws -> DiagnosticReport {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        return try DiagnosticReport(jsonData: data)
    }
}

extension RawBatteryReadings {
    /// 测试用：只有 IOPS 内置电池描述，其他来源为空。
    static func battery(
        _ powerSource: [String: RawValue],
        smartBattery: [String: RawValue]? = nil,
        smartBatteryPack: [String: RawValue]? = nil,
        adapterDetails: [String: RawValue]? = nil,
        chargeLimitArchive: RawValue? = nil
    ) -> RawBatteryReadings {
        var source = powerSource
        source["Type"] = .string("InternalBattery")
        return RawBatteryReadings(
            powerSources: [source],
            smartBattery: smartBattery,
            smartBatteryPack: smartBatteryPack,
            adapterDetails: adapterDetails,
            chargeLimitArchive: chargeLimitArchive,
            lowPowerModeEnabled: false
        )
    }
}

extension BatteryReading {
    var snapshot: BatterySnapshot? {
        if case .battery(let snapshot) = self { snapshot } else { nil }
    }
}
