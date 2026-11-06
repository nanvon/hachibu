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

    @Test func doesNotStartHoldingWhileCharging() {
        var charging = snapshot()
        charging.isCharging = true
        #expect(ChargeLimitHold.action(current: nil, snapshot: charging, isEnabled: true) == .none)
        // 校准结束、充电停止后按当时的电量开始保持。
        charging.isCharging = false
        charging.percent = 100
        #expect(ChargeLimitHold.action(current: nil, snapshot: charging, isEnabled: true)
            == .hold(ChargeLimitHold(userLimit: 80, heldLimit: 99)))
    }

    @Test func calibrationRestoresUserLimit() {
        var calibrating = snapshot(percent: 93, limit: .on(percent: 90))
        calibrating.isCharging = true
        calibrating.systemChargeState = .calibrating
        #expect(ChargeLimitHold.action(current: held, snapshot: calibrating, isEnabled: true) == .restore(held))
        // 电量回落后系统充回临时值：还没到临时值时不恢复。
        calibrating.percent = 85
        #expect(ChargeLimitHold.action(current: held, snapshot: calibrating, isEnabled: true) == .none)
        // 校准状态不变、充电已停止时继续保持。
        calibrating.percent = 90
        calibrating.isCharging = false
        #expect(ChargeLimitHold.action(current: held, snapshot: calibrating, isEnabled: true) == .none)
    }

    @Test func calibrationStatus() {
        var calibrating = snapshot(percent: 94)
        calibrating.isCharging = true
        calibrating.systemChargeState = .calibrating
        calibrating.timeToFullMinutes = 26
        #expect(ChargeStatus(calibrating) == .calibrating)
        #expect(calibrating.remainingTime == .untilFull(minutes: 26))

        calibrating.percent = 80
        #expect(ChargeStatus(calibrating) == .calibrating)
        // 还没到上限时和平常充电没有区别。
        calibrating.percent = 79
        #expect(ChargeStatus(calibrating) == .charging)
        // 上限关闭时没有被忽略的上限。
        calibrating.percent = 94
        calibrating.chargeLimit = .off
        #expect(ChargeStatus(calibrating) == .charging)
        // 没有校准状态时不归为校准。
        calibrating.chargeLimit = .on(percent: 80)
        calibrating.systemChargeState = nil
        #expect(ChargeStatus(calibrating) == .charging)
        // 未充电时不显示校准，按平常的规则。
        calibrating.systemChargeState = .calibrating
        calibrating.isCharging = false
        #expect(ChargeStatus(calibrating) == .chargeLimitReached(limit: 80))
    }

    @Test func temporaryFullChargeStatus() {
        // 临时充满期间系统上限读数为 100，不和电量比较。
        var charging = snapshot(percent: 86, limit: .on(percent: 100))
        charging.isCharging = true
        charging.systemChargeState = .temporaryFullCharge
        charging.timeToFullMinutes = 34
        #expect(ChargeStatus(charging) == .temporaryFullCharge)
        #expect(charging.remainingTime == .untilFull(minutes: 34))
        // 没有在充电时按平常的规则。
        charging.isCharging = false
        charging.percent = 100
        #expect(ChargeStatus(charging) == .fullyCharged)
        // 校准优先，且只影响达到上限之后。
        charging.isCharging = true
        charging.chargeLimit = .on(percent: 80)
        charging.systemChargeState = .calibrating
        #expect(ChargeStatus(charging) == .calibrating)
    }

    @Test func temporaryFullChargeKeepsSavedLimit() {
        var charging = snapshot(percent: 92, limit: .on(percent: 100))
        charging.isCharging = true
        charging.systemChargeState = .temporaryFullCharge
        // 上限读数变成 100 不算被别处改过，关闭选项或应用启动时也不写入。
        #expect(ChargeLimitHold.action(current: held, snapshot: charging, isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: held, snapshot: charging, isEnabled: false) == .none)
        #expect(ChargeLimitHold.action(current: held, snapshot: charging, isEnabled: true, restoresFirst: true) == .none)
        // 不开始新的保持。
        var stopped = snapshot(percent: 100)
        stopped.systemChargeState = .temporaryFullCharge
        #expect(ChargeLimitHold.action(current: nil, snapshot: stopped, isEnabled: true) == .none)

        // 结束后系统恢复临时值，继续保持；变成别的值时才丢弃。
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(percent: 100, limit: .on(percent: 90)), isEnabled: true) == .none)
        #expect(ChargeLimitHold.action(current: held, snapshot: snapshot(percent: 100, limit: .on(percent: 100)), isEnabled: true) == .forget)
    }

    @Test func statusDuringTemporaryFullChargeWithSavedHold() {
        var full = snapshot(percent: 100, limit: .on(percent: 100))
        full.chargeLimitHold = held
        full.systemChargeState = .temporaryFullCharge
        full.batteryPowerMW = 0
        #expect(ChargeStatus(full) == .fullyCharged)
        full.isCharging = true
        #expect(ChargeStatus(full) == .temporaryFullCharge)
    }

    @Test func optimizedChargingPausedStatus() {
        var paused = snapshot(percent: 72, limit: .on(percent: 90))
        paused.batteryPowerMW = 0
        paused.systemChargeState = .optimizedChargingPaused
        #expect(ChargeStatus(paused) == .optimizedChargingPaused)
        #expect(paused.remainingTime == nil)
        // 上限关闭时也可能暂停。
        paused.chargeLimit = .off
        #expect(ChargeStatus(paused) == .optimizedChargingPaused)
        // 达到上限时显示上限，已经在充电时显示充电。
        paused.chargeLimit = .on(percent: 70)
        #expect(ChargeStatus(paused) == .chargeLimitReached(limit: 70))
        paused.chargeLimit = .on(percent: 90)
        paused.isCharging = true
        #expect(ChargeStatus(paused) == .charging)
        // 放电时不算暂停。
        paused.isCharging = false
        paused.batteryPowerMW = -12000
        #expect(ChargeStatus(paused) == .pluggedInDraining)
    }

    @Test func optimizedChargingDischargingStatus() {
        var draining = snapshot(percent: 91, limit: .on(percent: 96))
        draining.chargeLimitHold = ChargeLimitHold(userLimit: 80, heldLimit: 96)
        draining.systemChargeState = .optimizedChargingDischarging(limit: 80)
        draining.batteryPowerMW = -25000
        draining.powerInMW = 100
        #expect(ChargeStatus(draining) == .optimizedChargingDischarging(limit: 80))
        #expect(draining.remainingTime == nil)

        draining.systemChargeState = .optimizedChargingDischarging(limit: nil)
        #expect(ChargeStatus(draining) == .optimizedChargingDischarging(limit: nil))
        draining.systemChargeState = nil
        #expect(ChargeStatus(draining) == .pluggedInDraining)
        draining.systemChargeState = .optimizedChargingDischarging(limit: 80)
        draining.isCharging = true
        #expect(ChargeStatus(draining) == .charging)
        draining.isCharging = false
        draining.isExternalPower = false
        #expect(ChargeStatus(draining) == .onBattery)
    }

    @Test func systemChargeStateFromUIState() {
        #expect(SystemChargeState(uiState: 18) == .calibrating)
        #expect(SystemChargeState(uiState: 3) == .temporaryFullCharge)
        #expect(SystemChargeState(uiState: 6) == .optimizedChargingPaused)
        #expect(SystemChargeState(uiState: 10) == .optimizedChargingPaused)
        #expect(SystemChargeState(uiState: 12, uiChargeLimit: 80) == .optimizedChargingDischarging(limit: 80))
        #expect(SystemChargeState(uiState: 12, uiChargeLimit: 0) == .optimizedChargingDischarging(limit: nil))
        #expect(SystemChargeState(uiState: 12, uiChargeLimit: 101) == .optimizedChargingDischarging(limit: nil))
        for other in [0, 1, 2, 4, 5, 7, 8, 9, 11, 13, 14, 15, 16, 17, 19] {
            #expect(SystemChargeState(uiState: other) == nil)
        }
    }

    @Test func parsesCalibrationFromPowerUI() {
        func parsed(_ uiState: Int?, uiChargeLimit: Int? = nil) -> SystemChargeState? {
            let raw = RawBatteryReadings(
                powerSources: [["Type": .string("InternalBattery")]],
                smartBattery: nil, smartBatteryPack: nil, adapterDetails: nil, chargeLimitArchive: nil,
                powerUIChargeLimit: PowerUIChargeLimit(isSupported: true, isEnabled: true, limit: 96, uiState: uiState, uiChargeLimit: uiChargeLimit),
                lowPowerModeEnabled: false
            )
            guard case .battery(let snapshot) = BatteryReading(raw) else { return nil }
            return snapshot.systemChargeState
        }
        #expect(parsed(18) == .calibrating)
        #expect(parsed(12, uiChargeLimit: 80) == .optimizedChargingDischarging(limit: 80))
        #expect(parsed(12) == .optimizedChargingDischarging(limit: nil))
        #expect(parsed(0) == nil)
        #expect(parsed(nil) == nil)
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
