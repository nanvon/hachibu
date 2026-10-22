import CoreFoundation
import Foundation

/// 属性列表中的一个值，保留原始类型。用于诊断导出和测试 fixture。
///
/// JSON 编码时，布尔、整数、字符串、数组、字典用 JSON 原生类型；其余类型编码为单键对象：
/// `{"$real": 0.7}`、`{"$data": "<base64>"}`、`{"$date": "<ISO 8601>"}`、`{"$uid": 3}`。
public enum RawValue: Sendable, Equatable {
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case string(String)
    case data(Data)
    case date(Date)
    /// NSKeyedArchiver 归档中的对象引用。
    case uid(UInt64)
    case array([RawValue])
    case dictionary([String: RawValue])
}

// MARK: - 从 CF / Foundation 对象转换

extension RawValue {
    /// 从 IOKit、PropertyListSerialization、JSONSerialization 返回的对象转换。
    /// 不认识的类型返回 nil；数组、字典中不认识的元素会被丢弃。
    public init?(propertyList object: Any) {
        let cfObject = object as AnyObject
        if CFGetTypeID(cfObject) == CFBooleanGetTypeID() {
            self = .bool(CFBooleanGetValue((cfObject as! CFBoolean)))
        } else if let number = object as? NSNumber {
            // IORegistry 的整数按有符号 64 位解析；ioreg 显示的超大正数实际是负数。
            self = CFNumberIsFloatType(number) ? .real(number.doubleValue) : .int(number.int64Value)
        } else if let string = object as? String {
            self = .string(string)
        } else if let data = object as? Data {
            self = .data(data)
        } else if let date = object as? Date {
            self = .date(date)
        } else if let array = object as? [Any] {
            self = .array(array.compactMap { RawValue(propertyList: $0) })
        } else if let dictionary = object as? [String: Any] {
            self = .dictionary(dictionary.compactMapValues { RawValue(propertyList: $0) })
        } else if let uid = Self.archiverUID(cfObject) {
            self = .uid(uid)
        } else {
            return nil
        }
    }

    /// CF 没有公开读取 `CFKeyedArchiverUID` 的接口，只能从描述 `"<CFKeyedArchiverUID 0x… [0x…]>{value = 3}"` 中取值。
    private static func archiverUID(_ object: AnyObject) -> UInt64? {
        guard (CFCopyTypeIDDescription(CFGetTypeID(object)) as String) == "CFKeyedArchiverUID" else { return nil }
        let description = CFCopyDescription(object) as String
        guard let start = description.range(of: "{value = "),
              let end = description[start.upperBound...].firstIndex(of: "}")
        else { return nil }
        return UInt64(description[start.upperBound..<end])
    }
}

// MARK: - 取值

extension RawValue {
    subscript(key: String) -> RawValue? {
        dictionaryValue?[key]
    }

    var intValue: Int? {
        if case .int(let value) = self { Int(exactly: value) } else { nil }
    }

    /// 整数和浮点数都接受。
    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var arrayValue: [RawValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    var dictionaryValue: [String: RawValue]? {
        if case .dictionary(let value) = self { value } else { nil }
    }
}

// MARK: - 脱敏

extension RawValue {
    /// 删除键名包含 `Serial` 或 `UUID`（不区分大小写）的字段，以及 `ManufacturerData`、`MfgData`
    /// 和 `extraKeys` 中的字段。递归处理所有层级。
    func redacted(extraKeys: Set<String> = []) -> RawValue {
        switch self {
        case .array(let values):
            .array(values.map { $0.redacted(extraKeys: extraKeys) })
        case .dictionary(let dictionary):
            .dictionary(Self.redact(dictionary, extraKeys: extraKeys))
        default:
            self
        }
    }

    static func redact(_ dictionary: [String: RawValue], extraKeys: Set<String> = []) -> [String: RawValue] {
        var result: [String: RawValue] = [:]
        for (key, value) in dictionary where !isRedactedKey(key, extraKeys: extraKeys) {
            result[key] = value.redacted(extraKeys: extraKeys)
        }
        return result
    }

    private static func isRedactedKey(_ key: String, extraKeys: Set<String>) -> Bool {
        let lowercased = key.lowercased()
        return lowercased.contains("serial")
            || lowercased.contains("uuid")
            || key == "ManufacturerData"
            || key == "MfgData"
            || extraKeys.contains(key)
    }
}

// MARK: - Codable

extension RawValue: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let realTag = "$real"
    private static let dataTag = "$data"
    private static let dateTag = "$date"
    private static let uidTag = "$uid"

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .real(let value):
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(value, forKey: Key(Self.realTag))
        case .data(let value):
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(value.base64EncodedString(), forKey: Key(Self.dataTag))
        case .date(let value):
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(value.formatted(Self.dateStyle), forKey: Key(Self.dateTag))
        case .uid(let value):
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(value, forKey: Key(Self.uidTag))
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .dictionary(let dictionary):
            var container = encoder.container(keyedBy: Key.self)
            for (key, value) in dictionary {
                try container.encode(value, forKey: Key(key))
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Int64.self) {
                self = .int(value)
                return
            }
            // 只出现在 `$real` 标签内部；顶层的浮点数也按 real 读取。
            if let value = try? container.decode(Double.self) {
                self = .real(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
            if let values = try? container.decode([RawValue].self) {
                self = .array(values)
                return
            }
        }

        let dictionary = try decoder.singleValueContainer().decode([String: RawValue].self)
        self = try Self.untagged(dictionary, codingPath: decoder.codingPath)
    }

    private static func untagged(_ dictionary: [String: RawValue], codingPath: [any CodingKey]) throws -> RawValue {
        guard dictionary.count == 1, let (tag, value) = dictionary.first else { return .dictionary(dictionary) }
        func invalid() -> DecodingError {
            DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid \(tag) value"))
        }
        switch tag {
        case realTag:
            guard let real = value.doubleValue else { throw invalid() }
            return .real(real)
        case dataTag:
            guard let string = value.stringValue, let data = Data(base64Encoded: string) else { throw invalid() }
            return .data(data)
        case dateTag:
            guard let string = value.stringValue, let date = try? dateStyle.parse(string) else { throw invalid() }
            return .date(date)
        case uidTag:
            guard case .int(let int) = value, let uid = UInt64(exactly: int) else { throw invalid() }
            return .uid(uid)
        default:
            return .dictionary(dictionary)
        }
    }
}
