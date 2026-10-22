import Foundation
import Testing
@testable import BatteryCore

@Suite struct RawValueTests {
    @Test func convertsFoundationObjects() {
        let object: [String: Any] = [
            "bool": true,
            "int": NSNumber(value: 1),
            "real": NSNumber(value: 0.7),
            "string": "text",
            "data": Data([0x01, 0x02]),
            "date": Date(timeIntervalSince1970: 0),
            "array": [NSNumber(value: 1), "a"],
            "nested": ["key": NSNumber(value: false)],
        ]
        #expect(RawValue(propertyList: object) == .dictionary([
            "bool": .bool(true),
            "int": .int(1),
            "real": .real(0.7),
            "string": .string("text"),
            "data": .data(Data([0x01, 0x02])),
            "date": .date(Date(timeIntervalSince1970: 0)),
            "array": .array([.int(1), .string("a")]),
            "nested": .dictionary(["key": .bool(false)]),
        ]))
    }

    @Test func parsesLargeUnsignedAsSigned() {
        let number = NSNumber(value: UInt64(18_446_744_073_709_543_405))
        #expect(RawValue(propertyList: number) == .int(-8211))
    }

    @Test func readsArchiverUID() throws {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: ["value"], requiringSecureCoding: true)
        let plist = try PropertyListSerialization.propertyList(from: archived, format: nil)
        let value = try #require(RawValue(propertyList: plist))
        #expect(value["$top"]?["root"] == .uid(1))
    }

    @Test func jsonRoundTripKeepsTypes() throws {
        let value: RawValue = .dictionary([
            "bool": .bool(false),
            "int": .int(-8211),
            "wholeReal": .real(2.0),
            "real": .real(0.7),
            "string": .string("$real"),
            "data": .data(Data([0xff, 0x00])),
            "date": .date(Date(timeIntervalSince1970: 1_792_662_522.5)),
            "uid": .uid(3),
            "array": .array([.int(1), .array([])]),
            "emptyDictionary": .dictionary([:]),
            "archiveKeys": .dictionary(["$class": .uid(7), "$classname": .string("NSUUID")]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(RawValue.self, from: data) == value)
    }

    @Test func redactsSensitiveKeysAtAnyDepth() {
        let value: RawValue = .dictionary([
            "Serial": .string("A"),
            "BatteryData": .dictionary([
                "serial": .string("B"),
                "Voltage": .int(12241),
                "MfgData": .data(Data([0x00])),
            ]),
            "AdapterDetails": .array([.dictionary(["SerialString": .string("C"), "Watts": .int(140)])]),
            "bootSessionUUID": .string("D"),
            "ManufacturerData": .data(Data([0x00])),
            "ManufactureDate": .int(1),
            "token": .uid(4),
        ])
        #expect(value.redacted() == .dictionary([
            "BatteryData": .dictionary(["Voltage": .int(12241)]),
            "AdapterDetails": .array([.dictionary(["Watts": .int(140)])]),
            "ManufactureDate": .int(1),
            "token": .uid(4),
        ]))
        #expect(value.redacted(extraKeys: ["token"])["token"] == nil)
    }
}
