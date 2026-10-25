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

    @Test func powerUIResultTakesPrecedence() {
        let file = archive(soclimit: .int(85))
        #expect(ChargeLimitSetting.resolve(
            powerUI: PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80), archive: file
        ) == .on(percent: 80))
        #expect(ChargeLimitSetting.resolve(
            powerUI: PowerUIChargeLimit(isSupported: true, isEnabled: false, limit: 80), archive: file
        ) == .off)
        #expect(ChargeLimitSetting.resolve(powerUI: PowerUIChargeLimit(isSupported: false), archive: file) == .unsupported)
    }

    @Test func fallsBackToFileWhenPowerUIIncomplete() {
        let file = archive(soclimit: .int(85))
        #expect(ChargeLimitSetting.resolve(powerUI: nil, archive: file) == .on(percent: 85))
        #expect(ChargeLimitSetting.resolve(
            powerUI: PowerUIChargeLimit(isSupported: true, isEnabled: nil, limit: 80), archive: file
        ) == .on(percent: 85))
        #expect(ChargeLimitSetting.resolve(
            powerUI: PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 0), archive: file
        ) == .on(percent: 85))
        #expect(ChargeLimitSetting.resolve(powerUI: nil, archive: nil) == nil)
    }

    @Test func optionsComeFromPowerUI() {
        func options(_ powerUI: PowerUIChargeLimit?) -> [Int]? {
            var raw = RawBatteryReadings.battery([:])
            raw.powerUIChargeLimit = powerUI
            return BatteryReading(raw).snapshot?.chargeLimitOptions
        }
        #expect(options(PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80, availableLimits: [100, 80, 90, 85, 95]))
            == [80, 85, 90, 95, 100])
        #expect(options(PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80, availableLimits: [0, 80, 120])) == [80])
        #expect(options(PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80, availableLimits: [])) == nil)
        #expect(options(PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 80)) == nil)
        #expect(options(PowerUIChargeLimit(isSupported: false, availableLimits: [80, 100])) == nil)
        #expect(options(nil) == nil)
    }

    @Test func changeIsAppliedOnlyWhenReadBackMatches() {
        #expect(ChargeLimitChange.enable.isApplied(to: .on(percent: 80)))
        #expect(!ChargeLimitChange.enable.isApplied(to: .off))
        #expect(ChargeLimitChange.disable.isApplied(to: .off))
        #expect(!ChargeLimitChange.disable.isApplied(to: .on(percent: 80)))
        #expect(ChargeLimitChange.limit(85).isApplied(to: .on(percent: 85)))
        #expect(!ChargeLimitChange.limit(85).isApplied(to: .on(percent: 80)))
        #expect(!ChargeLimitChange.limit(85).isApplied(to: .off))
        #expect(!ChargeLimitChange.enable.isApplied(to: nil))
        #expect(!ChargeLimitChange.disable.isApplied(to: .unsupported))
    }

    @Test func missingFileReadsAsNil() {
        let url = URL(fileURLWithPath: "/nonexistent/com.apple.powerd.charging.plist")
        #expect(ChargeLimitFile.readArchive(at: url) == nil)
    }
}
