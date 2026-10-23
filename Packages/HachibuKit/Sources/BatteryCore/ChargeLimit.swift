import Foundation

/// 系统充电上限设置（“系统设置 → 电池 → 充电上限”）。规则见 docs/v1技术设计.md 第 6 节。
public enum ChargeLimitSetting: Sendable, Equatable {
    /// 本机系统或机型不支持充电上限。
    case unsupported
    case off
    case on(percent: Int)

    /// 优先用 PowerUI 的结果；PowerUI 不可用或读不到开关、上限时，退回读取充电上限文件。都读不到时为 nil（未知）。
    static func resolve(powerUI: PowerUIChargeLimit?, archive: RawValue?) -> ChargeLimitSetting? {
        if let powerUI {
            guard powerUI.isSupported else { return .unsupported }
            if powerUI.isEnabled == false { return .off }
            if powerUI.isEnabled == true, let limit = powerUI.limit, (50...100).contains(limit) {
                return .on(percent: limit)
            }
        }
        return ChargeLimitFile.chargeLimit(inArchive: archive).map { .on(percent: $0) }
    }
}

/// 系统充电上限的私有文件。
enum ChargeLimitFile {
    static let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")

    /// 读取文件中 `policies` 字段并解开归档。文件不存在或格式不符时返回 nil。
    static func readArchive(at url: URL = url) -> RawValue? {
        guard let data = try? Data(contentsOf: url),
              let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let policies = top["policies"] as? Data,
              let archive = try? PropertyListSerialization.propertyList(from: policies, format: nil)
        else { return nil }
        return RawValue(propertyList: archive)
    }

    /// 在归档的 `ChargeCtrlPolicy` 数组中找 `reason == "manualChargeLimit"` 且 `soclimit` 为 50–100 的整数。
    /// 其他任何情况都返回 nil（未知）。
    static func chargeLimit(inArchive archive: RawValue?) -> Int? {
        guard let archive,
              archive["$archiver"]?.stringValue == "NSKeyedArchiver",
              let objects = archive["$objects"]?.arrayValue
        else { return nil }

        func resolve(_ value: RawValue?) -> RawValue? {
            guard case .uid(let index)? = value else { return value }
            guard let index = Int(exactly: index), objects.indices.contains(index) else { return nil }
            return objects[index]
        }

        guard let policies = resolve(archive["$top"]?["root"])?["NS.objects"]?.arrayValue else { return nil }
        for policy in policies.compactMap(resolve) {
            guard resolve(policy["reason"])?.stringValue == "manualChargeLimit",
                  let limit = resolve(policy["soclimit"])?.intValue,
                  (50...100).contains(limit)
            else { continue }
            return limit
        }
        return nil
    }
}
