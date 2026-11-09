import Foundation

/// 充电接管和校准的诊断信息，由 App 层从 BatteryMonitor 组装。见 docs/v1技术设计.md 21.7。
public struct ChargeControlDiagnostics: Sendable, Equatable, Codable {
    /// `ChargeControlMode` 的原始值。
    public var mode: String
    public var target: Int
    public var keepsLimitOnQuit: Bool
    /// 后台组件的注册状态，如 `enabled`、`requiresApproval`。
    public var helperState: String
    /// helper 读取的偏好里的两个值（`MCLFeatureState`、`mclLimitValue`）和其他状态；读不到时为 nil。
    public var helperStatus: ChargeHelperStatus?
    /// `pmset -g battlimit` 原文；没有读取过时为 nil。
    public var battlimitOutput: String?
    /// 解析后的登记结果；无法确认时为 nil。
    public var registration: ChargeLimitRegistration?
    public var calibration: CalibrationProgress?
    /// 接管模式下上限是否生效的描述，跟随系统设置时为 nil。
    public var managedLimitState: String?

    public init(
        mode: String,
        target: Int,
        keepsLimitOnQuit: Bool,
        helperState: String,
        helperStatus: ChargeHelperStatus? = nil,
        battlimitOutput: String? = nil,
        registration: ChargeLimitRegistration? = nil,
        calibration: CalibrationProgress? = nil,
        managedLimitState: String? = nil
    ) {
        self.mode = mode
        self.target = target
        self.keepsLimitOnQuit = keepsLimitOnQuit
        self.helperState = helperState
        self.helperStatus = helperStatus
        self.battlimitOutput = battlimitOutput
        self.registration = registration
        self.calibration = calibration
        self.managedLimitState = managedLimitState
    }
}

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
    /// 5.1 节各 SMC key 的原始读数，键为 key 名。打不开 SMC 连接时为 nil，读不到的 key 不写。
    public var smc: [String: SMCRawValue]?
    /// 充电接管和校准信息。旧文件没有这个字段。
    public var chargeControl: ChargeControlDiagnostics?

    public static let currentFormatVersion = 1

    /// 读取当前数据并脱敏。
    public static func collect(
        dataSource: any BatteryDataSource = IOKitBatteryDataSource(),
        systemProfiler: any SystemProfilerSource = SystemProfilerReader(),
        smcReader: @Sendable () -> [SMCKey: SMCRawValue]? = { SMCReader.shared.readRaw(SMCKey.allCases) },
        chargeControl: ChargeControlDiagnostics? = nil
    ) async throws -> DiagnosticReport {
        let readings = try dataSource.read()
        let smc = smcReader()
        let profilerOutput = try? await systemProfiler.readPowerData()
        return DiagnosticReport(
            formatVersion: currentFormatVersion,
            exportedAt: Date(),
            system: .current(),
            readings: readings.redacted(),
            systemProfilerPower: profilerOutput?.redacted(),
            smc: smc.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) },
            chargeControl: chargeControl
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
        systemProfilerPower: RawValue?,
        smc: [String: SMCRawValue]? = nil,
        chargeControl: ChargeControlDiagnostics? = nil
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.system = system
        self.readings = readings
        self.systemProfilerPower = systemProfilerPower
        self.smc = smc
        self.chargeControl = chargeControl
    }

    /// `smc` 中能识别的 key 的原始读数。
    public var smcValues: [SMCKey: SMCRawValue] {
        Dictionary(uniqueKeysWithValues: (smc ?? [:]).compactMap { name, value in
            SMCKey(rawValue: name).map { ($0, value) }
        })
    }

    // `readings` 的字段平铺在顶层，导出文件少一层嵌套。
    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, system, systemProfilerPower, smc, chargeControl
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        system = try container.decode(SystemInfo.self, forKey: .system)
        systemProfilerPower = try container.decodeIfPresent(RawValue.self, forKey: .systemProfilerPower)
        smc = try container.decodeIfPresent([String: SMCRawValue].self, forKey: .smc)
        chargeControl = try container.decodeIfPresent(ChargeControlDiagnostics.self, forKey: .chargeControl)
        readings = try RawBatteryReadings(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(system, forKey: .system)
        try container.encodeIfPresent(systemProfilerPower, forKey: .systemProfilerPower)
        try container.encodeIfPresent(smc, forKey: .smc)
        try container.encodeIfPresent(chargeControl, forKey: .chargeControl)
        try readings.encode(to: encoder)
    }
}
