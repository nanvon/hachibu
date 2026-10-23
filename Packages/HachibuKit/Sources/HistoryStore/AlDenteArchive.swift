import CoreFoundation
import CryptoKit
import Foundation

/// 已验证的原始导出格式。SQL、时间字符串和异常值仅保存，不执行或修正。
public struct AlDenteArchive: Sendable {
    public let identifier: String
    public let sourceVersion: String
    public let sourceBuild: String
    public let tables: [AlDenteTableSummary]
    public var recordCount: Int { records.count }

    let data: Data
    let records: [AlDenteRecord]

    public init(data: Data) throws {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AlDenteArchiveError.invalidJSON
            }
            root = object
        } catch {
            throw AlDenteArchiveError.invalidJSON
        }
        guard root["format"] as? String == "hachibu.aldente.raw" else {
            throw AlDenteArchiveError.unsupportedFormat
        }
        guard Self.integer(root["formatVersion"]) == 1 else {
            throw AlDenteArchiveError.unsupportedVersion
        }
        guard let source = root["source"] as? [String: Any],
              source["app"] as? String == "AlDente",
              source["bundleIdentifier"] as? String == "com.apphousekitchen.aldente-pro",
              let version = source["version"] as? String, !version.isEmpty,
              let build = source["build"] as? String, !build.isEmpty
        else { throw AlDenteArchiveError.invalidSource }

        let expectedNames = Set(AlDenteTable.allCases.map(\.rawValue))
        guard let sourceTables = root["tables"] as? [String: [String: Any]],
              Set(sourceTables.keys) == expectedNames,
              let schema = root["schema"] as? [[String: Any]]
        else { throw AlDenteArchiveError.incompleteTables }
        let schemaTables = schema.filter { $0["type"] as? String == "table" }
        guard schemaTables.count == expectedNames.count,
              Set(schemaTables.compactMap { $0["name"] as? String }) == expectedNames,
              schemaTables.allSatisfy({
                  $0["name"] as? String == $0["table"] as? String && $0["sql"] is String
              })
        else { throw AlDenteArchiveError.incompleteTables }

        var summaries: [AlDenteTableSummary] = []
        var records: [AlDenteRecord] = []
        for table in AlDenteTable.allCases {
            guard let content = sourceTables[table.rawValue],
                  let columns = content["columns"] as? [[String: Any]], columns.count == 3,
                  let rows = content["rows"] as? [[String: Any]],
                  Self.integer(content["rowCount"]) == Int64(rows.count)
            else { throw AlDenteArchiveError.invalidTable(table.rawValue) }
            let names = ["id", "timestamp", "value"]
            let types = ["INTEGER", "TEXT", table.valueType]
            for index in names.indices {
                let column = columns[index]
                guard column["name"] as? String == names[index],
                      column["type"] as? String == types[index],
                      Self.integer(column["position"]) == Int64(index),
                      Self.integer(column["notNull"]) == 1,
                      Self.integer(column["primaryKey"]) == (index == 0 ? 1 : 0),
                      column["default"] is NSNull
                else { throw AlDenteArchiveError.invalidTable(table.rawValue) }
            }
            var identifiers: Set<Int64> = []
            var timestamps: [String] = []
            for row in rows {
                guard Set(row.keys) == Set(names),
                      let id = Self.integer(row["id"]), identifiers.insert(id).inserted,
                      let timestamp = row["timestamp"] as? String
                else { throw AlDenteArchiveError.invalidTable(table.rawValue) }
                let value: Data
                switch table.valueType {
                case "INTEGER":
                    guard let number = Self.integer(row["value"]) else {
                        throw AlDenteArchiveError.invalidTable(table.rawValue)
                    }
                    value = Self.bytes(UInt64(bitPattern: number))
                case "REAL":
                    guard let number = row["value"] as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
                    else { throw AlDenteArchiveError.invalidTable(table.rawValue) }
                    value = Self.bytes(number.doubleValue.bitPattern)
                default:
                    guard let text = row["value"] as? String else {
                        throw AlDenteArchiveError.invalidTable(table.rawValue)
                    }
                    value = Data(text.utf8)
                }
                records.append(AlDenteRecord(table: table, sourceID: id, timestamp: timestamp, value: value))
                timestamps.append(timestamp)
            }
            summaries.append(AlDenteTableSummary(
                table: table, recordCount: rows.count,
                firstTimestamp: timestamps.min(), lastTimestamp: timestamps.max()
            ))
        }
        self.data = data
        identifier = Self.digest(data)
        sourceVersion = version
        sourceBuild = build
        tables = summaries
        self.records = records
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number)
        else { return nil }
        return Int64(number.stringValue)
    }

    static func bytes(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AlDenteTable: String, CaseIterable, Sendable {
    case batteryCycles, batteryDesignCap, batteryMaxCap, batteryPercentage, batterySerial
    case batteryTemp, chargeLimit, chargingPower, lastCalibration
    case macOSbatteryCondition, macOSbatteryMaxCap, systemLoad, systemPowerIn

    var valueType: String {
        switch self {
        case .batterySerial, .macOSbatteryCondition: "TEXT"
        case .batteryTemp, .chargingPower, .lastCalibration, .systemLoad, .systemPowerIn: "REAL"
        default: "INTEGER"
        }
    }
}

public struct AlDenteTableSummary: Sendable {
    public let table: AlDenteTable
    public let recordCount: Int
    /// 原始字符串，不转换时区，也不将其当作校准事件发生时间。
    public let firstTimestamp: String?
    public let lastTimestamp: String?
}

public enum AlDenteArchiveError: Error, Equatable {
    case invalidJSON, unsupportedFormat, unsupportedVersion, invalidSource, incompleteTables
    case invalidTable(String)
    case verificationFailed
}

struct AlDenteRecord: Sendable, Equatable {
    let identifier: String
    let table: AlDenteTable
    let sourceID: Int64
    let timestamp: String
    /// INTEGER 为有符号整数位模式，REAL 为 IEEE 754 位模式，均采用大端；TEXT 为 UTF-8。
    let value: Data

    init(table: AlDenteTable, sourceID: Int64, timestamp: String, value: Data) {
        self.table = table
        self.sourceID = sourceID
        self.timestamp = timestamp
        self.value = value
        // 长度前缀避免字符串边界歧义；包含类型和原值，保留同 ID 的不同历史记录。
        var identity = Data()
        for part in [Data(table.rawValue.utf8), AlDenteArchive.bytes(UInt64(bitPattern: sourceID)),
                     Data(timestamp.utf8), Data(table.valueType.utf8), value] {
            identity.append(AlDenteArchive.bytes(UInt64(part.count)))
            identity.append(part)
        }
        identifier = AlDenteArchive.digest(identity)
    }
}
