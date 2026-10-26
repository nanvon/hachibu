import Testing
@testable import BatteryCore

@Suite struct ChargeLimitHoldTests {
    private func snapshot(percent: Int? = 90, external: Bool? = true, limit: ChargeLimitSetting? = .on(percent: 80)) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isExternalPower: external, isCharging: false, chargeLimit: limit)
    }

    private let held = ChargeLimitHold(userLimit: 80, heldLimit: 90)

    @Test func startsHoldingAboveLimit() {
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(), isEnabled: true) == .hold(held))
        // 100% 时最高写 99。
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(percent: 100), isEnabled: true)
            == .hold(ChargeLimitHold(userLimit: 80, heldLimit: 99)))
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(percent: 100, limit: .on(percent: 95)), isEnabled: true)
            == .hold(ChargeLimitHold(userLimit: 95, heldLimit: 99)))
    }

    @Test func doesNotHoldOtherwise() {
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(), isEnabled: false) == .none)
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(percent: 80), isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(external: false), isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(external: nil), isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(limit: .off), isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(limit: nil), isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(percent: nil), isEnabled: true) == .none)
        // 上限 99 时 100% 也不需要保持。
        #expect(ChargeLimitHold.action(current: nil, snapshot: snapshot(percent: 100, limit: .on(percent: 99)), isEnabled: true) == .none)
    }

    @Test func keepsHoldingWhileConditionsHold() {
        let holding = snapshot(limit: .on(percent: 90))
        #expect(ChargeLimitHold.action(current: held, snapshot: holding, isEnabled: true) == .none)
        // 电量回落时系统会充回临时值，不改。
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(percent: 85, limit: .on(percent: 90)), isEnabled: true) == .none)
    }

    @Test func restoresUserLimit() {
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(external: false, limit: .on(percent: 90)), isEnabled: true)
            == .restore(held))
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(limit: .on(percent: 90)), isEnabled: false)
            == .restore(held))
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(limit: .on(percent: 90)), isEnabled: true, restoresFirst: true)
            == .restore(held))
    }

    @Test func forgetsWhenChangedElsewhere() {
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(limit: .on(percent: 85)), isEnabled: true) == .forget)
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(limit: .off), isEnabled: true) == .forget)
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(external: false, limit: .on(percent: 80)), isEnabled: true) == .forget)
        // 读不到时等待。
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(limit: nil), isEnabled: false) == .none)
    }

    @Test func statusWhileHolding() {
        var holding = snapshot(limit: .on(percent: 90))
        holding.chargeLimitHold = held
        holding.batteryPowerMW = 0
        #expect(ChargeStatus(holding) == .holdingCharge(percent: 90))
        holding.isCharging = true
        #expect(ChargeStatus(holding) == .charging)
        // 100% 写 99 后系统用电池放到 99%：目标值用系统实际上限。
        var draining = snapshot(percent: 100, limit: .on(percent: 99))
        draining.chargeLimitHold = ChargeLimitHold(userLimit: 80, heldLimit: 99)
        draining.batteryPowerMW = -20000
        draining.powerInMW = 100
        #expect(ChargeStatus(draining) == .aboveChargeLimit(limit: 99))
    }
}
