import Foundation

/// 系统充电上限的私有文件。规则见 docs/v1技术设计.md 第 6 节。
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
