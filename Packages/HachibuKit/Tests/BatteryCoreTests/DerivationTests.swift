import Foundation
import Testing
@testable import BatteryCore

@Suite struct ChargeStatusTests {
    private func status(
        external: Bool?,
        charging: Bool? = false,
        batteryPower: Int? = 0,
        percent: Int? = 70,
        limit: Int? = nil,
        reached: Bool = false,
        powerIn: Int? = nil
    ) -> ChargeStatus? {
        ChargeStatus(BatterySnapshot(
            percent: percent,
            isExternalPower: external,
            isCharging: charging,
            batteryPowerMW: batteryPower,
            powerInMW: powerIn,
            chargeLimit: limit.map { .on(percent: $0) },
            hasReachedChargeLimit: reached
        ))
    }

    @Test func unknownExternalPower() {
        #expect(status(external: nil) == nil)
    }

    @Test func rulesInOrder() {
        #expect(status(external: false, charging: true) == .onBattery)
        #expect(status(external: true, charging: true, batteryPower: -600) == .charging)
        #expect(status(external: true, batteryPower: -501, percent: 100) == .pluggedInDraining)
        // 高于上限、充电器不供电：本机实测输入 165 mW、电池 −25.8 W。
        #expect(status(external: true, batteryPower: -25800, percent: 81, limit: 80, powerIn: 165)
            == .aboveChargeLimit(limit: 80))
        #expect(status(external: true, batteryPower: -25800, percent: 80, limit: 80, powerIn: 165) == .pluggedInDraining)
        // 充电器功率不够或输入功率未知，都不归为高于上限。
        #expect(status(external: true, batteryPower: -12000, percent: 90, limit: 80, powerIn: 30000) == .pluggedInDraining)
        #expect(status(external: true, batteryPower: -12000, percent: 90, limit: 80) == .pluggedInDraining)
        #expect(status(external: true, batteryPower: -12000, percent: 90, powerIn: 165) == .pluggedInDraining)
        #expect(status(external: true, batteryPower: -500) == .pluggedInNotCharging)
        #expect(status(external: true, percent: 100, limit: 80) == .fullyCharged)
        #expect(status(external: true, percent: 80, limit: 80) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 85, limit: 80) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 79, limit: 80, reached: true) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 75, limit: 80, reached: true) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 74, limit: 80, reached: true) == .pluggedInNotCharging)
        // 未到达过上限（如刚把上限从 80% 调到 85%，系统还没开始充电）。
        #expect(status(external: true, percent: 80, limit: 85) == .pluggedInNotCharging)
        #expect(status(external: true, percent: 79, limit: 80) == .pluggedInNotCharging)
        #expect(status(external: true, percent: 80, limit: nil) == .pluggedInNotCharging)
        #expect(status(external: true, percent: nil, limit: 80) == .pluggedInNotCharging)
        #expect(status(external: true, charging: nil, batteryPower: nil) == .pluggedInNotCharging)
    }

    @Test func chargeLimitHoldTracker() {
        var tracker = ChargeLimitHoldTracker()
        func apply(
            percent: Int, external: Bool = true, charging: Bool = false, limit: ChargeLimitSetting? = .on(percent: 80)
        ) -> Bool {
            var snapshot = BatterySnapshot(
                percent: percent, isExternalPower: external, isCharging: charging, chargeLimit: limit
            )
            tracker.apply(to: &snapshot)
            return snapshot.hasReachedChargeLimit
        }

        #expect(apply(percent: 78) == false)
        #expect(apply(percent: 79, charging: true) == false)
        #expect(apply(percent: 80) == true)
        #expect(apply(percent: 77) == true)
        // 调高上限：清除，等系统重新充到新上限。
        #expect(apply(percent: 80, limit: .on(percent: 85)) == false)
        #expect(apply(percent: 85, limit: .on(percent: 85)) == true)
        // 关闭上限、拔电、开始充电都清除。
        #expect(apply(percent: 85, limit: .off) == false)
        #expect(apply(percent: 80) == true)
        #expect(apply(percent: 79, external: false) == false)
        #expect(apply(percent: 79) == false)
        #expect(apply(percent: 80) == true)
        #expect(apply(percent: 79, charging: true) == false)
        #expect(apply(percent: 79) == false)
    }

    @Test func remainingTime() {
        let onBattery = BatterySnapshot(isExternalPower: false, timeToEmptyMinutes: 120, timeToFullMinutes: 30)
        #expect(onBattery.remainingTime == .untilEmpty(minutes: 120))

        let charging = BatterySnapshot(isExternalPower: true, isCharging: true, timeToEmptyMinutes: 120, timeToFullMinutes: 30)
        #expect(charging.remainingTime == .untilFull(minutes: 30))

        let notCharging = BatterySnapshot(percent: 70, isExternalPower: true, isCharging: false, timeToEmptyMinutes: 120)
        #expect(notCharging.remainingTime == nil)

        let onBatteryUnknown = BatterySnapshot(isExternalPower: false)
        #expect(onBatteryUnknown.remainingTime == nil)
    }
}

@Suite struct PowerFlowTests {
    private func flow(external: Bool?, input: Int? = 12000, load: Int? = 10000, battery: Int?) -> PowerFlow? {
        PowerFlow(BatterySnapshot(
            isExternalPower: external,
            batteryPowerMW: battery,
            powerInMW: input,
            systemLoadMW: load
        ))
    }

    @Test func unknownExternalPower() {
        #expect(flow(external: nil, battery: 0) == nil)
    }

    @Test func charging() throws {
        let flow = try #require(self.flow(external: true, battery: 2000))
        #expect(flow.inputs == [.init(.charger, powerMW: 12000)])
        #expect(flow.outputs == [.init(.system, powerMW: 10000), .init(.battery, powerMW: 2000)])
        #expect(flow.computerMW == 12000)
    }

    @Test func smallBatteryPowerIsZero() throws {
        let flow = try #require(self.flow(external: true, battery: -499))
        #expect(flow.inputs == [.init(.charger, powerMW: 12000)])
        #expect(flow.outputs == [.init(.system, powerMW: 10000)])
        #expect(flow.computerMW == 10000)
    }

    @Test func pluggedInDraining() throws {
        let flow = try #require(self.flow(external: true, input: 7000, battery: -3000))
        #expect(flow.inputs == [.init(.battery, powerMW: 3000), .init(.charger, powerMW: 7000)])
        #expect(flow.outputs == [.init(.system, powerMW: 10000)])
        #expect(flow.computerMW == 10000)
    }

    @Test func onBattery() throws {
        let flow = try #require(self.flow(external: false, input: 0, load: 8000, battery: -8100))
        // 各流带取各自的原始读数，不配平。
        #expect(flow.inputs == [.init(.battery, powerMW: 8100)])
        #expect(flow.outputs == [.init(.system, powerMW: 8000)])
        #expect(flow.computerMW == 8000)
    }

    @Test func missingValues() throws {
        let noLoad = try #require(flow(external: true, load: nil, battery: -3000))
        #expect(noLoad.outputs == [.init(.system, powerMW: nil)])
        #expect(noLoad.computerMW == nil)

        let noBattery = try #require(flow(external: true, battery: nil))
        #expect(noBattery.inputs == [.init(.charger, powerMW: 12000)])
        #expect(noBattery.outputs == [.init(.system, powerMW: 10000)])

        let noInput = try #require(flow(external: true, input: nil, battery: 2000))
        #expect(noInput.inputs == [.init(.charger, powerMW: nil)])
        #expect(noInput.computerMW == nil)
    }
}

@Suite struct DiagnosticReportTests {
    private struct FakeDataSource: BatteryDataSource {
        func read() -> RawBatteryReadings {
            .battery(
                ["Hardware Serial Number": .string("X"), "Current Capacity": .int(80)],
                smartBattery: ["Serial": .string("X"), "Voltage": .int(12241)],
                chargeLimitArchive: .dictionary(["token": .uid(4), "soclimit": .int(80)])
            )
        }
    }

    private struct FailingProfiler: SystemProfilerSource {
        func readPowerData() async throws -> RawValue {
            throw SystemProfilerError.timedOut
        }
    }

    private struct FailingDataSource: BatteryDataSource {
        func read() throws -> RawBatteryReadings { throw BatteryDataSourceError.powerSourcesUnavailable }
    }

    @Test func collectDoesNotExportAReadFailureAsNoBattery() async {
        await #expect(throws: BatteryDataSourceError.self) {
            try await DiagnosticReport.collect(dataSource: FailingDataSource(), systemProfiler: FailingProfiler())
        }
    }

    @Test func collectRedactsAndToleratesProfilerFailure() async throws {
        let report = try await DiagnosticReport.collect(dataSource: FakeDataSource(), systemProfiler: FailingProfiler())
        #expect(report.formatVersion == DiagnosticReport.currentFormatVersion)
        #expect(report.readings.powerSources.first?["Hardware Serial Number"] == nil)
        #expect(report.readings.powerSources.first?["Current Capacity"] == .int(80))
        #expect(report.readings.smartBattery == ["Voltage": .int(12241)])
        #expect(report.readings.chargeLimitArchive == .dictionary(["soclimit": .int(80)]))
        #expect(report.systemProfilerPower == nil)
    }
}
