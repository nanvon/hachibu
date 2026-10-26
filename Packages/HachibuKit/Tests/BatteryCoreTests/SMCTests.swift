import Foundation
import Testing
@testable import BatteryCore

/// 小端序的单精度浮点字节。
private func le(_ value: Float) -> [UInt8] {
    let bits = value.bitPattern
    return [0, 8, 16, 24].map { UInt8(truncatingIfNeeded: bits >> $0) }
}

private func raw(_ key: SMCKey, _ bytes: [UInt8]) -> (SMCKey, SMCRawValue) {
    (key, SMCRawValue(type: key.expectedType, bytes: bytes))
}

@Suite struct SMCDecodingTests {
    /// 2026-10-26 本机插电未充电时读到的原始字节（`hachibu-diagnostics smc`）。
    @Test func decodesRecordedLittleEndianBytes() {
        let readings = SMCReadings(Dictionary(uniqueKeysWithValues: [
            raw(.charging, [0x00]),
            raw(.batteryPower, [0x00, 0x00, 0x00, 0x00]),
            raw(.batteryCurrent, [0x00, 0x00]),
            raw(.batteryVoltage, [0xdf, 0x2f]),
            raw(.powerIn, [0x4b, 0x5a, 0x39, 0x42]),
            raw(.systemPower, [0xaf, 0x0f, 0x1f, 0x42]),
            raw(.inputVoltage, [0x5a, 0x41, 0xde, 0x41]),
            raw(.inputCurrent, [0xec, 0x82, 0xd5, 0x3f]),
            raw(.temperature, [0xc8, 0xcc, 0xe8, 0x41]),
            raw(.chargeLimit, [0x50, 0x05, 0x05]),
        ]))
        #expect(readings == SMCReadings(
            isCharging: false,
            batteryPowerMW: 0,
            batteryCurrentMA: 0,
            batteryVoltageMV: 12255,
            powerInMW: 46338,
            systemPowerMW: 39765,
            inputVoltageMV: 27782,
            inputCurrentMA: 1668,
            temperatureCelsius: 29.1,
            chargeLimit: .on(percent: 80)
        ))
    }

    @Test func decodesSignedValues() {
        let readings = SMCReadings(Dictionary(uniqueKeysWithValues: [
            raw(.charging, [0x01]),
            // −25800 mW、−1500 mA，小端序补码。
            raw(.batteryPower, [0x38, 0x9b, 0xff, 0xff]),
            raw(.batteryCurrent, [0x24, 0xfa]),
            raw(.powerIn, le(0.000_05)),
        ]))
        #expect(readings.isCharging == true)
        #expect(readings.batteryPowerMW == -25800)
        #expect(readings.batteryCurrentMA == -1500)
        // 未插电时约 5e-5 W，换算成 mW 后为 0。
        #expect(readings.powerInMW == 0)
    }

    @Test func chargeLimitBytes() {
        func limit(_ bytes: [UInt8]) -> ChargeLimitSetting? {
            SMCReadings(Dictionary(uniqueKeysWithValues: [raw(.chargeLimit, bytes)])).chargeLimit
        }
        #expect(limit([0x50, 0x05, 0x05]) == .on(percent: 80))
        #expect(limit([0x64, 0x05, 0x05]) == .on(percent: 100))
        #expect(limit([0x00, 0x00, 0x00]) == .off)
        #expect(limit([0x12, 0x05, 0x05]) == nil)
    }

    @Test func rejectsMismatchedTypeOrSize() {
        let readings = SMCReadings([
            .batteryVoltage: SMCRawValue(type: "si16", bytes: [0xdf, 0x2f]),
            .batteryPower: SMCRawValue(type: "si32", bytes: [0x00, 0x00]),
            .powerIn: SMCRawValue(type: "ui32", bytes: le(20)),
            .charging: SMCRawValue(type: "flag", bytes: [0x01]),
        ])
        #expect(readings == SMCReadings())
    }

    @Test func rejectsOutOfRangeValues() {
        let readings = SMCReadings(Dictionary(uniqueKeysWithValues: [
            raw(.charging, [0x02]),
            // 按大端解码 B0AV 会得到 57391，同样会因超出范围被拒绝；这里直接给超出范围的小端值。
            raw(.batteryVoltage, [0x2f, 0xe0]),
            raw(.powerIn, le(500)),
            raw(.systemPower, le(.nan)),
            raw(.inputVoltage, le(-1)),
            raw(.inputCurrent, le(.infinity)),
            raw(.temperature, le(150)),
            raw(.batteryCurrent, [0xff, 0x7f]),
        ]))
        #expect(readings == SMCReadings())
    }

    @Test func rawValueEncodesBytesAsHex() throws {
        let value = SMCRawValue(type: "hex_", bytes: [0x50, 0x05, 0x05])
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).contains("\"500505\""))
        #expect(try JSONDecoder().decode(SMCRawValue.self, from: data) == value)
    }

    @Test func displayScopeExcludesDiagnosticOnlyKeys() {
        #expect(SMCReadScope.charging.keys == [.charging])
        #expect(!SMCReadScope.display.keys.contains(.notChargingReason))
        #expect(SMCReadScope.display.keys.contains(.chargeLimit))
    }
}

@Suite struct SMCOverlayTests {
    private let base = BatterySnapshot(
        percent: 81,
        isExternalPower: true,
        isCharging: false,
        voltageMV: 12200,
        amperageMA: 0,
        batteryPowerMW: 0,
        powerInMW: 30000,
        systemLoadMW: 30000,
        inputVoltageMV: 28000,
        inputCurrentMA: 1000,
        temperatureCelsius: 30,
        chargeLimit: .on(percent: 80)
    )

    @Test func replacesOnlyReadableFields() {
        let snapshot = base.applying(SMCReadings(isCharging: true, batteryPowerMW: 25000, systemPowerMW: 12000))
        #expect(snapshot.isCharging == true)
        #expect(snapshot.batteryPowerMW == 25000)
        #expect(snapshot.systemLoadMW == 12000)
        // 读不到的 key 保留 IOPS / IORegistry 的原值。
        #expect(snapshot.powerInMW == 30000)
        #expect(snapshot.inputVoltageMV == 28000)
        #expect(snapshot.temperatureCelsius == 30)
        #expect(base.applying(SMCReadings()) == base)
    }

    @Test func statusUsesSMCBeforeTelemetryRefresh() {
        // IOPS / IORegistry 还是一分钟前的“未充电”，SMC 已经在充电。
        #expect(ChargeStatus(base) == .chargeLimitReached(limit: 80))
        #expect(ChargeStatus(base.applying(SMCReadings(isCharging: true, batteryPowerMW: 30000))) == .charging)
        // 调低上限后系统改用电池：SMC 已报告放电和输入功率接近 0。
        let above = base.applying(SMCReadings(isCharging: false, batteryPowerMW: -25800, powerInMW: 165))
        #expect(ChargeStatus(above) == .aboveChargeLimit(limit: 80))
    }

    @Test func powerFlowTakesEachValueFromItsKey() throws {
        let snapshot = base.applying(SMCReadings(batteryPowerMW: 20000, powerInMW: 47000, systemPowerMW: 26500))
        let flow = try #require(PowerFlow(snapshot))
        // 不做配平：47 W 不等于 26.5 W + 20 W。
        #expect(flow.inputs == [PowerFlow.Stream(.charger, powerMW: 47000)])
        #expect(flow.outputs == [PowerFlow.Stream(.system, powerMW: 26500), PowerFlow.Stream(.battery, powerMW: 20000)])
    }
}
