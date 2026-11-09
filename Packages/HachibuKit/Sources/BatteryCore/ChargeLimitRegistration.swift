import Foundation
import os

/// powerd 实际登记的手动充电上限，来自 `pmset -g battlimit`。规则见 docs/v1技术设计.md 21.2。
/// 只统计 `chargeSocLimitReason = manualChargeLimit` 且 `Terminated = 0` 的条目。
public struct ChargeLimitRegistration: Sendable, Equatable, Codable {
    /// 各条有效登记的上限（%），本机通常有 PowerUIAgent 和 powerd 两条，值相同。没有登记时为空。
    public var limits: [Int]

    public init(limits: [Int]) {
        self.limits = limits
    }

    /// 登记的上限一致时为这个值；没有登记或几条登记不一致时为 nil。
    public var limit: Int? {
        guard let first = limits.first, limits.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// 是否登记了 `percent`。100 表示不应有任何登记。
    public func registers(_ percent: Int) -> Bool {
        percent >= 100 ? limits.isEmpty : limit == percent
    }

    /// 解析 `pmset -g battlimit` 的输出。格式不认识时返回 nil（无法确认），不当成没有登记。
    public static func parse(_ output: String) -> ChargeLimitRegistration? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "No battery level limits set" || trimmed == "No battery level limits" {
            return ChargeLimitRegistration(limits: [])
        }
        guard trimmed.hasPrefix("Battery level limits:") else { return nil }
        let body = trimmed.dropFirst("Battery level limits:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("("), body.hasSuffix(")") else { return nil }
        let entries = body.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        if entries.isEmpty { return ChargeLimitRegistration(limits: []) }

        var limits: [Int] = []
        var entry: [String: String]?
        var entryCount = 0
        for rawLine in entries.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "{" {
                guard entry == nil else { return nil }
                entry = [:]
            } else if line == "}" || line == "}," {
                guard let current = entry else { return nil }
                entry = nil
                entryCount += 1
                guard let reason = current["chargeSocLimitReason"], !reason.isEmpty,
                      let terminated = current["Terminated"], ["0", "1"].contains(terminated) else { return nil }
                guard let soc = current["chargeSocLimitSoc"].flatMap(Int.init), (1...100).contains(soc) else { return nil }
                guard reason == "manualChargeLimit", terminated == "0" else { continue }
                limits.append(soc)
            } else if entry != nil, line.hasSuffix(";"), let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: equals)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "; \t\""))
                guard !key.isEmpty, !value.isEmpty, entry?[key] == nil else { return nil }
                entry?[key] = value
            } else {
                return nil
            }
        }
        // 条目没有闭合：输出被截断或格式变了。
        guard entry == nil, entryCount > 0 else { return nil }
        return ChargeLimitRegistration(limits: limits)
    }
}

/// 异步运行 `pmset -g battlimit`，超时 2 秒。
public enum ChargeLimitRegistrationReader {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "ChargeControl")

    /// 返回解析结果和原文。运行失败、超时或格式不认识时 `registration` 为 nil。
    public static func read(timeout: Duration = .seconds(2)) async -> (registration: ChargeLimitRegistration?, output: String?) {
        let output = await runPmset(timeout: timeout)
        guard let output else { return (nil, nil) }
        let registration = ChargeLimitRegistration.parse(output)
        if registration == nil {
            logger.error("Unrecognized pmset battlimit output")
        }
        return (registration, output)
    }

    private static func runPmset(timeout: Duration) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "battlimit"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            let once = OnceResume(continuation)
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                once.resume(process.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil)
            }
            do {
                try process.run()
            } catch {
                logger.error("Failed to run pmset: \(String(describing: error), privacy: .public)")
                once.resume(nil)
                return
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if process.isRunning {
                    process.terminate()
                    logger.error("pmset battlimit timed out")
                }
                once.resume(nil)
            }
        }
    }

    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: String?) {
            let pending = lock.withLock { () -> CheckedContinuation<String?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
