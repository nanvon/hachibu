import Foundation

/// 面板数值的显示格式。缺失的值显示“—”。单位不翻译。
enum DisplayFormat {
    static let missing = "—"

    /// 功率：W，一位小数。
    static func watts(milliwatts: Int?) -> String {
        guard let milliwatts else { return missing }
        return "\(decimal(Double(milliwatts) / 1000, fractionLength: 1)) W"
    }

    /// 充电器额定功率：整数 W。
    static func watts(_ watts: Int?) -> String {
        watts.map { "\($0) W" } ?? missing
    }

    static func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? missing
    }

    /// 0–1 的比值，显示为一位小数的百分比。
    static func percent(ratio: Double?) -> String {
        ratio.map { "\(decimal($0 * 100, fractionLength: 1))%" } ?? missing
    }

    static func celsius(_ value: Double?) -> String {
        value.map { "\(decimal($0, fractionLength: 1)) °C" } ?? missing
    }

    static func volts(millivolts: Int?, fractionLength: Int) -> String {
        millivolts.map { "\(decimal(Double($0) / 1000, fractionLength: fractionLength)) V" } ?? missing
    }

    /// 电流：A，两位小数，负数为放电。
    static func amps(milliamps: Int?) -> String {
        milliamps.map { "\(decimal(Double($0) / 1000, fractionLength: 2)) A" } ?? missing
    }

    static func number(_ value: Int?) -> String {
        value.map(String.init) ?? missing
    }

    /// 剩余时间，例如“3 小时 20 分钟”，按系统语言格式化。
    static func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private static func decimal(_ value: Double, fractionLength: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionLength)).grouping(.never))
    }
}
