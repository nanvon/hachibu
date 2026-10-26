import Foundation

/// 诊断导出，供用户提 issue 时附上，也用作测试 fixture。规则见 docs/v1技术设计.md 第 14 节。
public struct DiagnosticReport: Sendable, Equatable, Codable {
    public struct SystemInfo: Sendable, Equatable, Codable {
        /// 如 `27.0.1`。
        public var osVersion: String
        /// 如 `26A434`。
        public var osBuild: String?
        /// `hw.model`，如 `MacBookPro18,1`。
        public var model: String?

        public static func current() -> SystemInfo {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return SystemInfo(
                osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                osBuild: sysctlString("kern.osversion"),
                model: sysctlString("hw.model")
            )
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// 导出格式版本，格式不兼容时递增。
    public var formatVersion: Int
    public var exportedAt: Date
    public var system: SystemInfo
    /// 已脱敏。
    public var readings: RawBatteryReadings
    /// `system_profiler SPPowerDataType -json` 的输出，已脱敏；运行失败时为 nil。
    public var systemProfilerPower: RawValue?

    public static let currentFormatVersion = 1

    /// 读取当前数据并脱敏。
    public static func collect(
        dataSource: any BatteryDataSource = IOKitBatteryDataSource(),
        systemProfiler: any SystemProfilerSource = SystemProfilerReader()
    ) async throws -> DiagnosticReport {
        let readings = try dataSource.read()
        let profilerOutput = try? await systemProfiler.readPowerData()
        return DiagnosticReport(
            formatVersion: currentFormatVersion,
            exportedAt: Date(),
            system: .current(),
            readings: readings.redacted(),
            systemProfilerPower: profilerOutput?.redacted()
        )
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(DiagnosticReport.self, from: jsonData)
    }

    public init(
        formatVersion: Int,
        exportedAt: Date,
        system: SystemInfo,
        readings: RawBatteryReadings,
        systemProfilerPower: RawValue?
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.system = system
        self.readings = readings
        self.systemProfilerPower = systemProfilerPower
    }

    // `readings` 的字段平铺在顶层，导出文件少一层嵌套。
    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, system, systemProfilerPower
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        system = try container.decode(SystemInfo.self, forKey: .system)
        systemProfilerPower = try container.decodeIfPresent(RawValue.self, forKey: .systemProfilerPower)
        readings = try RawBatteryReadings(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(system, forKey: .system)
        try container.encodeIfPresent(systemProfilerPower, forKey: .systemProfilerPower)
        try readings.encode(to: encoder)
    }
}
