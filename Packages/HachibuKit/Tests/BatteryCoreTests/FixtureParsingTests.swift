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
        #expect(flow.inputs == [PowerFlow.Stream(.charger, powerMW: snapshot.powerInMW)])
        #expect(flow.outputs == [PowerFlow.Stream(.system, powerMW: 18099)])
        #expect(flow.computerMW == 18099)
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

/// 本机录制的使用电池数据。
@Suite struct OnBatteryFixtureTests {
    let report: DiagnosticReport

    init() throws {
        report = try Fixtures.report(Fixtures.onBattery)
    }

    @Test func snapshot() throws {
        let snapshot = try #require(BatteryReading(report.readings).snapshot)

        #expect(snapshot.percent == 79)
        #expect(snapshot.isExternalPower == false)
        #expect(snapshot.isCharging == false)
        #expect(snapshot.timeToEmptyMinutes == 301)
        #expect(snapshot.timeToFullMinutes == nil)

        #expect(snapshot.voltageMV == 11957)
        #expect(snapshot.amperageMA == -1387)
        // 使用电池时电池功率为负，绝对值等于系统功率；没有输入。
        #expect(snapshot.batteryPowerMW == -16159)
        #expect(snapshot.systemLoadMW == 16159)
        #expect(snapshot.powerInMW == 0)
        #expect(snapshot.inputVoltageMV == 0)
        #expect(snapshot.inputCurrentMA == 0)
        #expect(snapshot.telemetryUpdatedAt == Date(timeIntervalSince1970: 1_792_996_357))

        #expect(snapshot.temperatureCelsius == 28.59)
        #expect(snapshot.fullChargeCapacityMAh == 7882)
        #expect(snapshot.designCapacityMAh == 8694)
        #expect(snapshot.adapter == nil)
        #expect(snapshot.chargeLimitPercent == 80)
    }

    @Test func derivedState() throws {
        let snapshot = try #require(BatteryReading(report.readings).snapshot)

        #expect(ChargeStatus(snapshot) == .onBattery)
        #expect(snapshot.remainingTime == .untilEmpty(minutes: 301))

        let flow = try #require(PowerFlow(snapshot))
        #expect(flow.inputs == [PowerFlow.Stream(.battery, powerMW: 16159)])
        #expect(flow.outputs == [PowerFlow.Stream(.system, powerMW: 16159)])
        #expect(flow.computerMW == 16159)
    }
}

/// 本机录制的充电中数据。
@Suite struct ChargingFixtureTests {
    let report: DiagnosticReport

    init() throws {
        report = try Fixtures.report(Fixtures.charging)
    }

    @Test func snapshot() throws {
        let snapshot = try #require(BatteryReading(report.readings).snapshot)

        #expect(snapshot.percent == 78)
        #expect(snapshot.isExternalPower == true)
        #expect(snapshot.isCharging == true)
        #expect(snapshot.timeToEmptyMinutes == nil)
        #expect(snapshot.timeToFullMinutes == 53)

        #expect(snapshot.voltageMV == 12671)
        #expect(snapshot.amperageMA == 4477)
        // 充电时电池功率为正，输入功率等于系统功率加电池功率。
        #expect(snapshot.batteryPowerMW == 56807)
        #expect(snapshot.systemLoadMW == 26815)
        #expect(snapshot.powerInMW == 83622)
        #expect(snapshot.inputVoltageMV == 27518)
        #expect(snapshot.inputCurrentMA == 3038)
        #expect(snapshot.telemetryUpdatedAt == Date(timeIntervalSince1970: 1_792_996_734))

        #expect(snapshot.temperatureCelsius == 29.29)
        #expect(snapshot.fullChargeCapacityMAh == 7891)
        #expect(snapshot.adapter == PowerAdapter(watts: 140, name: "140W USB-C Power Adapter", manufacturer: "Apple Inc."))
        #expect(snapshot.chargeLimitPercent == 80)
    }

    @Test func derivedState() throws {
        let snapshot = try #require(BatteryReading(report.readings).snapshot)

        #expect(ChargeStatus(snapshot) == .charging)
        #expect(snapshot.remainingTime == .untilFull(minutes: 53))

        let flow = try #require(PowerFlow(snapshot))
        #expect(flow.inputs == [PowerFlow.Stream(.charger, powerMW: 83622)])
        #expect(flow.outputs == [PowerFlow.Stream(.system, powerMW: 26815), PowerFlow.Stream(.battery, powerMW: 56807)])
        #expect(flow.computerMW == 83622)
    }
}

/// 所有 fixture 都要已脱敏、能原样往返。
@Suite struct AllFixturesTests {
    @Test(arguments: Fixtures.all) func isRedacted(_ name: String) throws {
        let report = try Fixtures.report(name)
        let json = try #require(String(data: try report.jsonData(), encoding: .utf8))
        #expect(!json.localizedCaseInsensitiveContains("\"serial"))
        #expect(!json.localizedCaseInsensitiveContains("uuidbytes"))
        #expect(!json.contains("\"token\""))
        #expect(!json.contains("\"ManufacturerData\""))
        #expect(!json.contains("\"MfgData\""))
    }

    @Test(arguments: Fixtures.all) func roundTrip(_ name: String) throws {
        let report = try Fixtures.report(name)
        #expect(try DiagnosticReport(jsonData: try report.jsonData()) == report)
    }
}
