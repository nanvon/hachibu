// 把本机当前的电池原始数据（已脱敏）以 JSON 输出到标准输出，用于录制测试 fixture。
// 用法：swift run --package-path Packages/HachibuKit hachibu-diagnostics > Packages/HachibuKit/Tests/Fixtures/<名称>.json
import BatteryCore
import Foundation

let report = await DiagnosticReport.collect()
FileHandle.standardOutput.write(try report.jsonData())
FileHandle.standardOutput.write(Data("\n".utf8))
