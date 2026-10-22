import Foundation
import Testing
@testable import BatteryCore

/// 用本机录制的接电未充电数据测试完整解析。期望值取自 fixture 文件本身。
@Suite struct FixtureParsingTests {
    let report: DiagnosticReport

    init() throws {
        report = try Fixtures.report(Fixtures.acNotCharging)
    }

    @Test func metadata() {
        #expect(report.formatVersion == 1)
        #expect(report.system.model == "MacBookPro18,1")
        #expect(report.system.osVersion == "27.0.1")
    }

    @Test func snapshot() throws {
        let snapshot = try #require(BatteryReading(report.readings).snapshot)

        #expect(snapshot.percent == 80)
        #expect(snapshot.isExternalPower == true)
        #expect(snapshot.isCharging == false)
        #expect(snapshot.timeToEmptyMinutes == nil)
        #expect(snapshot.timeToFullMinutes == nil)

        #expect(snapshot.voltageMV == 12241)
        #expect(snapshot.amperageMA == 0)
        #expect(snapshot.batteryPowerMW == 0)
        #expect(snapshot.powerInMW == 18099)
        #expect(snapshot.systemLoadMW == 18099)
        #expect(snapshot.inputVoltageMV == 27985)
        #expect(snapshot.inputCurrentMA == 646)
        #expect(snapshot.telemetryUpdatedAt == Date(timeIntervalSince1970: 1_792_662_522))

        #expect(snapshot.temperatureCelsius == 27.0)
        #expect(snapshot.fullChargeCapacityMAh == 7942)
        #expect(snapshot.designCapacityMAh == 8694)
        #expect(snapshot.cycleCount == 68)
        #expect(snapshot.designCycleCount == 1000)
        let ratio = try #require(snapshot.capacityRatio)
        #expect(abs(ratio - 0.9135) < 0.0001)

        #expect(snapshot.adapter == PowerAdapter(watts: 140, name: "140W USB-C Power Adapter", manufacturer: "Apple Inc."))
        #expect(snapshot.lowPowerModeEnabled == false)
        #expect(snapshot.chargeLimitPercent == 80)
    }

    @Test func derivedState() throws {
        let snapshot = try #require(BatteryReading(report.readings).snapshot)

        #expect(ChargeStatus(snapshot) == .chargeLimitReached(limit: 80))
        #expect(snapshot.remainingTime == nil)

        let flow = try #require(PowerFlow(snapshot))
        #expect(flow.links == [PowerFlow.Link(from: .charger, to: .computer, powerMW: 18099)])
        #expect(flow.caption == .pluggedInIdle(loadMW: 18099))
    }

    @Test func health() {
        let health = BatteryHealthInfo(systemProfilerPower: report.systemProfilerPower)
        #expect(health.systemMaximumCapacityPercent == 95)
        #expect(health.condition == .good)
    }

    @Test func preservesTypes() throws {
        let idealCRate = report.readings.smartBatteryPack?["BatteryData"]?["IdealCRate"]
        guard case .real? = idealCRate else {
            Issue.record("IdealCRate 应为浮点数，实际为 \(String(describing: idealCRate))")
            return
        }
        #expect(report.readings.smartBattery?["ExternalConnected"] == .bool(true))
        // ioreg 显示为 18446744073709543405 的值按有符号解析为负数。
        #expect(report.readings.smartBatteryPack?["BatteryData"]?["LifetimeData"]?["MaximumDischargeCurrent"] == .int(-8211))
    }

    @Test func isRedacted() throws {
        let json = try #require(String(data: try report.jsonData(), encoding: .utf8))
        #expect(!json.localizedCaseInsensitiveContains("\"serial"))
        #expect(!json.localizedCaseInsensitiveContains("uuidbytes"))
        #expect(!json.contains("\"token\""))
        #expect(!json.contains("\"ManufacturerData\""))
        #expect(!json.contains("\"MfgData\""))
    }

    @Test func roundTrip() throws {
        let decoded = try DiagnosticReport(jsonData: try report.jsonData())
        #expect(decoded == report)
    }
}
