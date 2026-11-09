import BatteryCore
import Foundation
import HistoryStore
import ServiceManagement
import Testing
@testable import FeatureUI

@Test func helperRegistrationStatesOfferAppropriateActions() {
    let cases: [(SMAppService.Status?, ChargeHelperState, ChargeHelperState.Action)] = [
        (nil, .notRegistered, .install),
        (.notRegistered, .notRegistered, .install),
        (.notFound, .unavailable, .install),
        (.requiresApproval, .requiresApproval, .approve),
        (.enabled, .enabled, .remove),
    ]
    for (status, expectedState, expectedAction) in cases {
        let state = ChargeHelperState(status: status)
        #expect(state == expectedState)
        #expect(state.action == expectedAction)
        #expect(state.canInstall == (expectedAction == .install))
    }
}

/// 所有写入只发生在内存假系统中，不注册 helper、不修改本机充电设置。
private final class ManagedTestSystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var state = (percent: 90, enabled: true, limit: 80, uiState: 0, fails: false)
    private var log: [ChargeLimitChange] = []

    var writes: [ChargeLimitChange] { lock.withLock { log } }
    var setting: ChargeLimitSetting { lock.withLock { state.enabled ? .on(percent: state.limit) : .off } }

    func set(percent: Int? = nil, limit: Int? = nil, uiState: Int? = nil, fails: Bool? = nil) {
        lock.withLock {
            if let percent { state.percent = percent }
            if let limit { state.limit = limit; state.enabled = limit < 100 }
            if let uiState { state.uiState = uiState }
            if let fails { state.fails = fails }
        }
    }

    func read() -> RawBatteryReadings {
        lock.withLock {
            RawBatteryReadings(
                powerSources: [[
                    "Type": .string("InternalBattery"), "Current Capacity": .int(Int64(state.percent)),
                    "Max Capacity": .int(100), "Power Source State": .string("AC Power"), "Is Charging": .bool(false),
                ]],
                smartBattery: nil, smartBatteryPack: nil, adapterDetails: nil, chargeLimitArchive: nil,
                powerUIChargeLimit: PowerUIChargeLimit(
                    isSupported: true, isEnabled: state.enabled, limit: state.limit,
                    availableLimits: [80, 85, 90, 95, 100], uiState: state.uiState
                ), lowPowerModeEnabled: false
            )
        }
    }

    func write(_ change: ChargeLimitChange) throws {
        try lock.withLock {
            log.append(change)
            if state.fails { throw ChargeLimitWriteError(message: "test write failure") }
            switch change {
            case .enable: state.enabled = true
            case .disable, .limit(100): state.enabled = false
            case .limit(let percent): state.enabled = true; state.limit = percent
            }
        }
    }
}

private struct ManagedTestProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}

@MainActor
@Suite struct ChargeControlMonitorTests {
    private let defaults = UserDefaults(suiteName: "ChargeControlMonitorTests.\(UUID().uuidString)")!
    private let system = ManagedTestSystem()

    private func monitor(store: HistoryStore? = nil) -> BatteryMonitor {
        BatteryMonitor(
            sampler: BatterySampler(dataSource: system, systemProfiler: ManagedTestProfiler(), chargeLimitWriter: system, store: store),
            powerSourceReader: { nil }, smcReader: { _ in nil }, holdDefaults: defaults,
            helperService: ChargeHelperService(service: nil)
        )
    }

    private func settle(_ monitor: BatteryMonitor) async {
        for _ in 0..<200 {
            await Task.yield()
            if !monitor.isWritingChargeLimit { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Managed write did not settle")
    }

    @Test func takeoverRestoresOriginalOnSwitchAndExit() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        await monitor.read()
        await settle(monitor)
        #expect(system.setting == .on(percent: 85))
        #expect(monitor.managedOriginal == .on(percent: 80))
        monitor.chargeControl.mode = .followSystem
        await settle(monitor)
        #expect(system.setting == .on(percent: 80))
        #expect(monitor.managedOriginal == nil)

        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 95)
        await settle(monitor)
        monitor.restoreChargeLimitBeforeExit()
        #expect(system.setting == .on(percent: 80))
        #expect(defaults.data(forKey: BatteryMonitor.managedOriginalKey) == nil)
    }

    @Test func systemPolicyPreventsWritesAndEndReappliesTarget() async {
        system.set(uiState: 18)
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        monitor.holdsChargeAboveLimit = true
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.isEmpty)
        system.set(uiState: 0)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.first == .limit(85))
    }

    @Test func holdDoesNotWriteDuringSystemPolicyEvenIfTargetAlreadyMatches() async {
        system.set(limit: 85, uiState: 6)
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        monitor.holdsChargeAboveLimit = true
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.isEmpty)
    }

    @Test func helperApprovalFallbackPreservesRequestedTarget() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 60)
        await monitor.read()
        await settle(monitor)
        #expect(monitor.managedDesiredLimit == 80)
        #expect(monitor.chargeControl.target == 60)
        #expect(monitor.managedLimitState == .awaitingHelperApproval(effective: 80))
        #expect(system.writes.isEmpty)
    }

    @Test func externalChangeIsRevertedOnceAndFailuresAreThrottled() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        await monitor.read()
        await settle(monitor)
        monitor.managedLastWrite = nil
        system.set(limit: 95)
        await monitor.read()
        await settle(monitor)
        #expect(system.setting == .on(percent: 85))
        #expect(monitor.externalChangeRevertedAt != nil)

        system.set(limit: 95, fails: true)
        monitor.managedLastWrite = nil
        await monitor.read()
        await settle(monitor)
        let count = system.writes.count
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.count == count)
        #expect(monitor.managedWriteFailed)
    }

    @Test func pauseCancelAndQuitRestoreTheExpectedLimits() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        await monitor.read()
        await settle(monitor)
        monitor.startCalibration(from: .chargeToFull)
        await settle(monitor)
        #expect(system.setting == .off)
        monitor.pauseCalibration()
        await settle(monitor)
        #expect(system.setting == .on(percent: 85))
        monitor.resumeCalibration()
        await settle(monitor)
        #expect(system.setting == .off)
        monitor.cancelCalibration()
        await settle(monitor)
        #expect(system.setting == .on(percent: 85))
        monitor.startCalibration(from: .chargeToFull)
        await settle(monitor)
        monitor.restoreChargeLimitBeforeExit()
        #expect(system.setting == .on(percent: 80))
        let restored = self.monitor()
        #expect(restored.calibration?.pauseReason == .appQuit)
        #expect(CalibrationEngine.requestedLimit(for: restored.calibration!) == nil)
    }

    @Test func failedCalibrationWritePausesImmediately() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 80)
        await monitor.read()
        system.set(fails: true)
        monitor.startCalibration(from: .chargeToFull)
        await settle(monitor)
        #expect(monitor.calibration?.pauseReason == .writeFailed)
    }

    @Test func rapidCancelAndRestartKeepsSeparateDatabaseRecords() async throws {
        let store = try HistoryStore.inMemory()
        let monitor = monitor(store: store)
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 80)
        await monitor.read()
        monitor.startCalibration(from: .holdFull)
        monitor.cancelCalibration()
        monitor.startCalibration(from: .chargeToFull)
        await settle(monitor)
        _ = await monitor.calibrationRecordTask?.value
        let runs = try await store.calibrationRuns()
        #expect(runs.count == 2)
        #expect(runs.filter { $0.result == .cancelled }.count == 1)
        #expect(runs.filter { $0.result == nil }.count == 1)
        #expect(monitor.calibrationRecordIDs.run == runs.first?.id)
    }
}
