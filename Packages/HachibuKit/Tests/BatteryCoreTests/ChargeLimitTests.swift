import Foundation
import Testing
@testable import BatteryCore

@Suite struct ChargeLimitTests {
    /// 与本机文件相同结构的归档：NSMutableArray 里放一个 ChargeCtrlPolicy。
    private func archive(reason: String = "manualChargeLimit", soclimit: RawValue = .int(80)) -> RawValue {
        .dictionary([
            "$archiver": .string("NSKeyedArchiver"),
            "$version": .int(100_000),
            "$top": .dictionary(["root": .uid(1)]),
            "$objects": .array([
                .string("$null"),
                .dictionary(["$class": .uid(5), "NS.objects": .array([.uid(2)])]),
                .dictionary(["$class": .uid(4), "reason": .uid(3), "soclimit": soclimit]),
                .string(reason),
                .dictionary(["$classname": .string("ChargeCtrlPolicy")]),
                .dictionary(["$classname": .string("NSMutableArray")]),
            ]),
        ])
    }

    @Test func readsFixture() throws {
        let report = try Fixtures.report(Fixtures.acNotCharging)
        #expect(ChargeLimitFile.chargeLimit(inArchive: report.readings.chargeLimitArchive) == 80)
    }

    @Test(arguments: [50, 80, 100])
    func acceptsValidLimit(_ limit: Int) {
        #expect(ChargeLimitFile.chargeLimit(inArchive: archive(soclimit: .int(Int64(limit)))) == limit)
    }

    @Test(arguments: [RawValue.int(49), .int(101), .real(80), .string("80")])
    func rejectsInvalidLimit(_ soclimit: RawValue) {
        #expect(ChargeLimitFile.chargeLimit(inArchive: archive(soclimit: soclimit)) == nil)
    }

    @Test func rejectsOtherReason() {
        #expect(ChargeLimitFile.chargeLimit(inArchive: archive(reason: "optimizedCharging")) == nil)
    }

    @Test func unknownWhenArchiveMissingOrMalformed() {
        #expect(ChargeLimitFile.chargeLimit(inArchive: nil) == nil)
        #expect(ChargeLimitFile.chargeLimit(inArchive: .dictionary([:])) == nil)
        #expect(ChargeLimitFile.chargeLimit(inArchive: .dictionary([
            "$archiver": .string("NSKeyedArchiver"),
            "$top": .dictionary(["root": .uid(9)]),
            "$objects": .array([.string("$null")]),
        ])) == nil)
    }

    @Test func missingFileReadsAsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/com.apple.powerd.charging.plist")
        #expect(ChargeLimitFile.readArchive(at: url) == nil)
    }
}
