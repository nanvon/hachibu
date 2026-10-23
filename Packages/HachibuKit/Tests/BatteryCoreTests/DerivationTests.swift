import Foundation
import Testing
@testable import BatteryCore

@Suite struct ChargeStatusTests {
    private func status(
        external: Bool?,
        charging: Bool? = false,
        batteryPower: Int? = 0,
        percent: Int? = 70,
        limit: Int? = nil
    ) -> ChargeStatus? {
        ChargeStatus(BatterySnapshot(
            percent: percent,
            isExternalPower: external,
            isCharging: charging,
            batteryPowerMW: batteryPower,
            chargeLimit: limit.map { .on(percent: $0) }
        ))
    }

    @Test func unknownExternalPower() {
        #expect(status(external: nil) == nil)
    }

    @Test func rulesInOrder() {
        #expect(status(external: false, charging: true) == .onBattery)
        #expect(status(external: true, charging: true, batteryPower: -600) == .charging)
        #expect(status(external: true, batteryPower: -501, percent: 100) == .pluggedInDraining)
        #expect(status(external: true, batteryPower: -500) == .pluggedInNotCharging)
        #expect(status(external: true, percent: 100, limit: 80) == .fullyCharged)
        #expect(status(external: true, percent: 79, limit: 80) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 85, limit: 80) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 75, limit: 80) == .chargeLimitReached(limit: 80))
        #expect(status(external: true, percent: 74, limit: 80) == .pluggedInNotCharging)
        #expect(status(external: true, percent: 80, limit: nil) == .pluggedInNotCharging)
        #expect(status(external: true, percent: nil, limit: 80) == .pluggedInNotCharging)
        #expect(status(external: true, charging: nil, batteryPower: nil) == .pluggedInNotCharging)
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
        #expect(flow.links == [
            .init(from: .charger, to: .computer, powerMW: 10000),
            .init(from: .charger, to: .battery, powerMW: 2000),
        ])
        #expect(flow.chargerMW == 12000)
        #expect(flow.computerMW == 10000)
        #expect(flow.batteryMW == 2000)
        #expect(flow.caption == .charging(inputMW: 12000, loadMW: 10000, batteryMW: 2000))
    }

    @Test func smallBatteryPowerIsZero() throws {
        let flow = try #require(self.flow(external: true, battery: -499))
        #expect(flow.links == [.init(from: .charger, to: .computer, powerMW: 10000)])
        // 节点数值仍取原始读数。
        #expect(flow.batteryMW == 499)
        #expect(flow.caption == .pluggedInIdle(loadMW: 10000))
    }

    @Test func pluggedInDraining() throws {
        let flow = try #require(self.flow(external: true, input: 7000, battery: -3000))
        #expect(flow.links == [
            .init(from: .charger, to: .computer, powerMW: 7000),
            .init(from: .battery, to: .computer, powerMW: 3000),
        ])
        #expect(flow.caption == .pluggedInDraining(inputMW: 7000, batteryMW: 3000, loadMW: 10000))

        let clamped = try #require(self.flow(external: true, load: 2000, battery: -3000))
        #expect(clamped.links.first?.powerMW == 0)
    }

    @Test func onBattery() throws {
        let flow = try #require(self.flow(external: false, input: 0, load: 8000, battery: -8100))
        #expect(flow.links == [.init(from: .battery, to: .computer, powerMW: 8000)])
        #expect(flow.batteryMW == 8100)
        #expect(flow.caption == .onBattery(loadMW: 8000))
    }

    @Test func missingValuesHideCaption() throws {
        let noLoad = try #require(flow(external: true, load: nil, battery: 2000))
        #expect(noLoad.links.first?.powerMW == nil)
        #expect(noLoad.caption == nil)

        let noBattery = try #require(flow(external: true, battery: nil))
        #expect(noBattery.links == [.init(from: .charger, to: .computer, powerMW: 10000)])
        #expect(noBattery.caption == nil)

        let noInput = try #require(flow(external: true, input: nil, battery: -3000))
        #expect(noInput.caption == nil)
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

    @Test func collectRedactsAndToleratesProfilerFailure() async {
        let report = await DiagnosticReport.collect(dataSource: FakeDataSource(), systemProfiler: FailingProfiler())
        #expect(report.formatVersion == DiagnosticReport.currentFormatVersion)
        #expect(report.readings.powerSources.first?["Hardware Serial Number"] == nil)
        #expect(report.readings.powerSources.first?["Current Capacity"] == .int(80))
        #expect(report.readings.smartBattery == ["Voltage": .int(12241)])
        #expect(report.readings.chargeLimitArchive == .dictionary(["soclimit": .int(80)]))
        #expect(report.systemProfilerPower == nil)
    }
}
