// 把本机当前的电池原始数据（已脱敏）以 JSON 输出到标准输出，用于录制测试 fixture。
// 用法：swift run --package-path Packages/HachibuKit hachibu-diagnostics > Packages/HachibuKit/Tests/Fixtures/<名称>.json
// 对照 SMC 与 IOPS / IORegistry：hachibu-diagnostics smc [秒数]，每秒输出一行，只读。
import BatteryCore
import Foundation

if CommandLine.arguments.dropFirst().first == "smc" {
    let seconds = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 10
    func text(_ value: Any?) -> String { value.map { "\($0)" } ?? "—" }
    for second in 0..<max(seconds, 1) {
        let smc = SMCReader.shared.readRaw(SMCKey.allCases) ?? [:]
        let decoded = SMCReadings(smc)
        let snapshot: BatterySnapshot? = switch (try? IOKitBatteryDataSource().read()).map(BatteryReading.init) {
        case .battery(let snapshot)?: snapshot
        default: nil
        }
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
        let raw = SMCKey.allCases.map { key in
            "\(key.rawValue)=\(smc[key].map { $0.bytes.map { String(format: "%02x", $0) }.joined() } ?? "—")"
        }.joined(separator: " ")
        print("""
            \(time) SMC charging=\(text(decoded.isCharging)) battery=\(text(decoded.batteryPowerMW))mW \
            \(text(decoded.batteryCurrentMA))mA \(text(decoded.batteryVoltageMV))mV \
            in=\(text(decoded.powerInMW))mW system=\(text(decoded.systemPowerMW))mW \
            input=\(text(decoded.inputVoltageMV))mV/\(text(decoded.inputCurrentMA))mA \
            temp=\(text(decoded.temperatureCelsius)) limit=\(text(decoded.chargeLimit)) | \
            IOPS external=\(text(snapshot?.isExternalPower)) charging=\(text(snapshot?.isCharging)) \
            percent=\(text(snapshot?.percent)) | IORegistry battery=\(text(snapshot?.batteryPowerMW))mW \
            amperage=\(text(snapshot?.amperageMA))mA in=\(text(snapshot?.powerInMW))mW \
            system=\(text(snapshot?.systemLoadMW))mW temp=\(text(snapshot?.temperatureCelsius)) | \(raw)
            """)
        fflush(stdout)
        if second + 1 < seconds { try await Task.sleep(for: .seconds(1)) }
    }
} else {
    let report = try await DiagnosticReport.collect()
    FileHandle.standardOutput.write(try report.jsonData())
    FileHandle.standardOutput.write(Data("\n".utf8))
}
