import BatteryCore
import Foundation
import Testing
@testable import FeatureUI

/// 模拟电池和 PowerUI：电量、插电可调，记录每次写入，写入后读回新的开关和上限。
private final class HoldTestSystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var state = (
        percent: 90, external: true, charging: false, uiState: 0, enabled: true, limit: 80, failsWrites: false
    )
    private var log: [ChargeLimitChange] = []

    var writes: [ChargeLimitChange] { lock.withLock { log } }
    var limit: ChargeLimitSetting { lock.withLock { state.enabled ? .on(percent: state.limit) : .off } }

    func set(
        percent: Int? = nil, external: Bool? = nil, charging: Bool? = nil, uiState: Int? = nil,
        limit: Int? = nil, failsWrites: Bool? = nil
    ) {
        lock.withLock {
            if let percent { state.percent = percent }
            if let external { state.external = external }
            if let charging { state.charging = charging }
            if let uiState { state.uiState = uiState }
            if let limit { state.limit = limit }
            if let failsWrites { state.failsWrites = failsWrites }
        }
    }

    func read() -> RawBatteryReadings {
        lock.withLock {
            RawBatteryReadings(
                powerSources: [[
                    "Type": .string("InternalBattery"),
                    "Current Capacity": .int(Int64(state.percent)), "Max Capacity": .int(100),
                    "Power Source State": .string(state.external ? "AC Power" : "Battery Power"),
                    "Is Charging": .bool(state.charging),
                ]],
                smartBattery: nil, smartBatteryPack: nil, adapterDetails: nil, chargeLimitArchive: nil,
                powerUIChargeLimit: PowerUIChargeLimit(
                    isSupported: true, isEnabled: state.enabled,
                    limit: state.enabled ? state.limit : 100, availableLimits: [80, 85, 90, 95, 100],
                    uiState: state.uiState
                ),
                lowPowerModeEnabled: false
            )
        }
    }

    func write(_ change: ChargeLimitChange) throws {
        try lock.withLock {
            log.append(change)
            if state.failsWrites { throw ChargeLimitWriteError(message: "fake failure") }
            switch change {
            case .enable: state.enabled = true
            case .disable, .limit(100): state.enabled = false
            case .limit(let percent): state.limit = percent
            }
        }
    }
}

private struct NoProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}

@MainActor
@Suite struct ChargeLimitHoldMonitorTests {
    private let defaults: UserDefaults
    private let system = HoldTestSystem()

    init() {
        let suite = "ChargeLimitHoldMonitorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeMonitor(holds: Bool = true) -> BatteryMonitor {
        let monitor = BatteryMonitor(
            sampler: BatterySampler(dataSource: system, systemProfiler: NoProfiler(), chargeLimitWriter: system, store: nil),
            powerSourceReader: { nil },
            smcReader: { _ in nil },
            holdDefaults: defaults
        )
        monitor.holdsChargeAboveLimit = holds
        return monitor
    }

    /// 自动写入在单独的任务里执行，等它结束。
    private func settle(_ monitor: BatteryMonitor) async {
        for _ in 0..<200 {
            await Task.yield()
            if !monitor.isWritingChargeLimit { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Write did not finish")
    }

    private var savedHold: ChargeLimitHold? {
        defaults.data(forKey: "chargeLimitHold").flatMap { try? JSONDecoder().decode(ChargeLimitHold.self, from: $0) }
    }

    private func snapshot(_ monitor: BatteryMonitor) -> BatterySnapshot? {
        if case .battery(let snapshot)? = monitor.reading { snapshot } else { nil }
    }

    @Test func holdsCurrentChargeAndShowsUserLimit() async throws {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90)])
        #expect(system.limit == .on(percent: 90))
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 90))
        let batterySnapshot = try #require(snapshot(monitor))
        #expect(ChargeStatus(batterySnapshot) == .holdingCharge(percent: 90))
        let control = try #require(ChargeLimitControl(snapshot: batterySnapshot, canWrite: true, isBlocked: false))
        #expect(control.percent == 80)
    }

    @Test func calibrationDoesNotWriteUntilChargingStops() async throws {
        system.set(percent: 94, charging: true, uiState: 18)
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.isEmpty)
        #expect(savedHold == nil)
        #expect(ChargeStatus(try #require(snapshot(monitor))) == .calibrating)

        // 校准结束：充电停止后按当时的电量保持。
        system.set(percent: 100, charging: false, uiState: 0)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(99)])
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 99))
    }

    @Test func calibrationReleasesExistingHold() async throws {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90)])

        system.set(percent: 93, charging: true, uiState: 18)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80)])
        #expect(savedHold == nil)
        let calibrating = try #require(snapshot(monitor))
        #expect(ChargeStatus(calibrating) == .calibrating)
        #expect(ChargeLimitControl(snapshot: calibrating, canWrite: true, isBlocked: false)?.percent == 80)

        system.set(percent: 96, charging: false, uiState: 0)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80), .limit(96)])
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 96))
    }

    @Test func launchDuringCalibrationRestoresAndWaits() async {
        // 旧版本校准期间留下的临时值。
        system.set(percent: 96, charging: true, uiState: 18, limit: 93)
        defaults.set(try? JSONEncoder().encode(ChargeLimitHold(userLimit: 80, heldLimit: 93)), forKey: "chargeLimitHold")
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(80)])
        #expect(system.limit == .on(percent: 80))
        #expect(savedHold == nil)
    }

    @Test func temporaryFullChargeKeepsUserLimit() async throws {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90)])

        // 临时充满期间系统上限读数为 100。
        system.set(percent: 92, charging: true, uiState: 3, limit: 100)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90)])
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 90))
        let charging = try #require(snapshot(monitor))
        #expect(ChargeStatus(charging) == .temporaryFullCharge)
        #expect(ChargeLimitControl(snapshot: charging, canWrite: true, isBlocked: false)?.percent == 80)

        // 结束后系统恢复临时值，继续保持，拔电时写回用户的上限。
        system.set(percent: 100, charging: false, uiState: 0, limit: 90)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90)])
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 90))

        system.set(external: false)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80)])
        #expect(savedHold == nil)
    }

    @Test func exitDuringTemporaryFullChargeRestoresOnNextLaunch() async {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        system.set(percent: 92, charging: true, uiState: 3, limit: 100)
        await monitor.read()
        await settle(monitor)

        monitor.restoreChargeLimitBeforeExit()
        #expect(system.writes == [.limit(90)])
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 90))

        // 下次启动时临时充满已结束，系统恢复了临时值：先写回用户的上限，不把临时值当成用户的上限。
        system.set(percent: 90, charging: false, uiState: 0, limit: 90)
        let next = makeMonitor()
        await next.read()
        await settle(next)
        #expect(system.writes.dropFirst().first == .limit(80))
    }

    @Test func dischargeOptionDoesNotWrite() async {
        let monitor = makeMonitor(holds: false)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.isEmpty)
        #expect(savedHold == nil)
    }

    @Test func unplugRestoresUserLimit() async {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        system.set(external: false)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80)])
        #expect(system.limit == .on(percent: 80))
        #expect(savedHold == nil)
    }

    @Test func switchingOptionOffRestores() async {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        monitor.holdsChargeAboveLimit = false
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80)])
        #expect(savedHold == nil)
    }

    @Test func launchRestoresSavedHoldFirst() async {
        system.set(limit: 90)
        defaults.set(try? JSONEncoder().encode(ChargeLimitHold(userLimit: 80, heldLimit: 90)), forKey: "chargeLimitHold")
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        // 先恢复，再按条件重新开始保持。
        #expect(system.writes.prefix(2) == [.limit(80), .limit(90)])
        await settle(monitor)
        #expect(savedHold == ChargeLimitHold(userLimit: 80, heldLimit: 90))
    }

    @Test func changeElsewhereIsAdoptedWithoutWriting() async {
        system.set(percent: 84, limit: 85)
        defaults.set(try? JSONEncoder().encode(ChargeLimitHold(userLimit: 80, heldLimit: 90)), forKey: "chargeLimitHold")
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.isEmpty)
        #expect(savedHold == nil)
    }

    @Test func lowerLimitWhileHoldingOnlyUpdatesUserLimit() async throws {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        await monitor.setChargeLimit(.limit(85))
        #expect(system.writes == [.limit(90)])
        #expect(savedHold == ChargeLimitHold(userLimit: 85, heldLimit: 90))
        let batterySnapshot = try #require(snapshot(monitor))
        #expect(ChargeLimitControl(snapshot: batterySnapshot, canWrite: true, isBlocked: false)?.percent == 85)

        await monitor.setChargeLimit(.limit(95))
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(95)])
        #expect(savedHold == nil)
    }

    @Test func disablingWhileHoldingRestoresUserLimitFirst() async {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        await monitor.setChargeLimit(.disable)
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80), .disable])
        #expect(savedHold == nil)
    }

    @Test func fullLimitWhileHoldingRestoresUserLimitFirst() async {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        await monitor.setChargeLimit(.limit(100))
        await settle(monitor)
        #expect(system.writes == [.limit(90), .limit(80), .limit(100)])
        #expect(system.limit == .off)
        #expect(savedHold == nil)
    }

    @Test func limitWhileOffEnablesFirst() async {
        let monitor = makeMonitor(holds: false)
        await monitor.read()
        await monitor.setChargeLimit(.limit(100))
        #expect(system.limit == .off)
        await monitor.setChargeLimit(.limit(85))
        #expect(system.writes == [.limit(100), .enable, .limit(85)])
        #expect(system.limit == .on(percent: 85))
    }

    @Test func exitRestoresSynchronously() async {
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        monitor.restoreChargeLimitBeforeExit()
        #expect(system.writes == [.limit(90), .limit(80)])
        #expect(savedHold == nil)
    }

    @Test func failedHoldIsDroppedAndNotRetriedImmediately() async {
        system.set(failsWrites: true)
        let monitor = makeMonitor()
        await monitor.read()
        await settle(monitor)
        #expect(monitor.chargeLimitWriteFailed)
        #expect(savedHold == nil)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(90)])
    }
}
