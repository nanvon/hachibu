import Foundation

/// `system_profiler SPPowerDataType -json` 的读取来源。
public protocol SystemProfilerSource: Sendable {
    /// 返回解析后的 JSON 原始结构。
    func readPowerData() async throws -> RawValue
}

public enum SystemProfilerError: Error, Sendable, Equatable {
    case timedOut
    case exited(status: Int32)
    case invalidOutput
}

/// 用 `Process` 异步运行 `system_profiler`，超时后终止进程。
public struct SystemProfilerReader: SystemProfilerSource {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func readPowerData() async throws -> RawValue {
        let output = try await Self.run(
            executable: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
            arguments: ["SPPowerDataType", "-json"],
            timeout: timeout
        )
        guard let json = try? JSONSerialization.jsonObject(with: output),
              let value = RawValue(propertyList: json)
        else { throw SystemProfilerError.invalidOutput }
        return value
    }

    /// `Process` 没有标为 Sendable，只在下面的后台队列和超时回调里使用。
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private static func run(executable: URL, arguments: [String], timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let box = ProcessBox()
                let process = box.process
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                    if box.process.isRunning {
                        box.process.terminate()
                    }
                }

                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: SystemProfilerError.timedOut)
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: SystemProfilerError.exited(status: process.terminationStatus))
                } else {
                    continuation.resume(returning: output)
                }
            }
        }
    }
}

/// 来自 `system_profiler` 的电池健康信息。
public struct BatteryHealthInfo: Sendable, Equatable {
    /// 系统最大容量（%），即系统设置里显示的值。
    public var systemMaximumCapacityPercent: Int?
    public var condition: BatteryHealthCondition?

    public init(systemMaximumCapacityPercent: Int?, condition: BatteryHealthCondition?) {
        self.systemMaximumCapacityPercent = systemMaximumCapacityPercent
        self.condition = condition
    }

    /// 从 `spbattery_information` 的 `sppower_battery_health_info` 中读取。
    public init(systemProfilerPower: RawValue?) {
        let healthInfo = systemProfilerPower?["SPPowerDataType"]?.arrayValue?
            .first { $0["_name"]?.stringValue == "spbattery_information" }?["sppower_battery_health_info"]

        systemMaximumCapacityPercent = healthInfo?["sppower_battery_health_maximum_capacity"]?.stringValue
            .flatMap(Self.parsePercent)
        condition = healthInfo?["sppower_battery_health"]?.stringValue.map(BatteryHealthCondition.init)
    }

    /// 解析 `"95%"` 这样的字符串。
    private static func parsePercent(_ string: String) -> Int? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%"), let value = Int(trimmed.dropLast()), (0...100).contains(value) else {
            return nil
        }
        return value
    }
}

public enum BatteryHealthCondition: Sendable, Equatable {
    case good
    /// 其他值保留英文原文，界面原样显示。
    case other(String)

    init(_ rawValue: String) {
        self = rawValue == "Good" ? .good : .other(rawValue)
    }

    /// `system_profiler` 的原文，存入数据库。
    public var rawValue: String {
        switch self {
        case .good: "Good"
        case .other(let rawValue): rawValue
        }
    }
}
