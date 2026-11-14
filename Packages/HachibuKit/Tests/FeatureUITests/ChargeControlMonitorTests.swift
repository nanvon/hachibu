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

@MainActor
final class FakeHelperRegistration: ChargeHelperRegistration {
    var status: SMAppService.Status = .notRegistered
    var registrationError: Error?
    var removalError: Error?
    var statusOnRemovalError: SMAppService.Status?
    var statusAfterRegister: SMAppService.Status?
    var registrations = 0
    var unregistrations = 0

    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func unregister() async throws {
        unregistrations += 1
        if let removalError {
            if let statusOnRemovalError { status = statusOnRemovalError }
            throw removalError
        }
        status = .notRegistered
    }
}

@MainActor
@Test func helperRegistrationWaitsForSystemPermission() {
    let backend = FakeHelperRegistration()
    let service = ChargeHelperService(registration: backend)
    backend.statusAfterRegister = .requiresApproval
    service.register()
    #expect(service.state == .requiresApproval)
    #expect(service.registrationError == nil)
    #expect(!service.isReady)
    backend.status = .enabled
    service.refresh()
    #expect(service.state == .enabled)
}

@MainActor
@Test func helperRevocationAndRemovalFailurePreserveSystemState() async {
    let backend = FakeHelperRegistration()
    backend.status = .enabled
    let service = ChargeHelperService(registration: backend)
    backend.status = .requiresApproval
    service.refresh()
    #expect(service.state == .requiresApproval)

    backend.status = .enabled
    service.refresh()
    backend.removalError = NSError(domain: "test", code: 1)
    await service.unregister()
    #expect(service.state == .enabled)
    #expect(service.lastError != nil)
    backend.removalError = nil
    await service.unregister()
    #expect(service.state == .notRegistered)
    #expect(service.lastError == nil)
}

@MainActor
@Test func helperRegistrationDeniedByUserNeedsPermissionNotFailure() {
    // 用户在系统设置里关过开关后，register() 报“不允许”，状态为需要允许：引导允许，不报安装失败。
    let backend = FakeHelperRegistration()
    backend.status = .requiresApproval
    backend.registrationError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
    let service = ChargeHelperService(registration: backend)
    service.register()
    #expect(service.state == .requiresApproval)
    #expect(service.registrationError == nil)
    #expect(service.lastError != nil)
}

@MainActor
@Test func helperRegistrationFailureRemainsVisibleUntilRetried() {
    let backend = FakeHelperRegistration()
    let service = ChargeHelperService(registration: backend)
    backend.registrationError = NSError(domain: "test", code: 2)
    service.register()
    #expect(service.state == .notRegistered)
    #expect(service.registrationError != nil)
    service.refresh()
    #expect(service.registrationError != nil)

    backend.registrationError = nil
    backend.statusAfterRegister = .enabled
    service.register()
    #expect(backend.registrations == 2)
    #expect(service.state == .enabled)
    #expect(service.registrationError == nil)
}

@MainActor
@Test func helperReinstallUnregistersThenRegisters() async {
    let backend = FakeHelperRegistration()
    backend.status = .requiresApproval
    backend.statusAfterRegister = .requiresApproval
    let service = ChargeHelperService(registration: backend)
    await service.reinstall()
    #expect(backend.unregistrations == 1)
    #expect(backend.registrations == 1)
    #expect(service.state == .requiresApproval)
    #expect(!service.isBusy)

    // 注销失败也继续注册，结果以注册后的状态为准。
    backend.removalError = NSError(domain: "test", code: 1)
    backend.statusAfterRegister = .enabled
    await service.reinstall()
    #expect(backend.registrations == 2)
    #expect(service.state == .enabled)
}

@MainActor
@Test func unreachableEnabledHelperIsNotRegisteredAgain() async {
    // 已允许但连不上时不自动重新注册：重新注册会让系统重新核对，把用户刚打开的开关撤回。
    let backend = FakeHelperRegistration()
    backend.status = .enabled
    let service = ChargeHelperService(registration: backend)
    let status = await service.connectedStatus(retryDelay: .zero)
    #expect(status == nil)
    #expect(backend.registrations == 0)
    #expect(service.state == .enabled)
    #expect(service.registrationError == nil)
}

@MainActor
@Test func upgradeRegistersNewLabelAndUnregistersLegacyHelper() async {
    // 0.1.10 及更早只注册过固定 label，没有记录：按旧 helper 的状态判断，注册本版本并注销旧的。
    let current = FakeHelperRegistration()
    let legacy = FakeHelperRegistration()
    legacy.status = .enabled
    current.statusAfterRegister = .requiresApproval
    let defaults = UserDefaults(suiteName: "HelperMigration-\(UUID().uuidString)")!
    let label = "io.github.nanvon.hachibu.helper.0.1.11"
    let service = ChargeHelperService(
        registration: current, label: label,
        registrationForLabel: { $0 == ChargeHelper.legacyLabel ? legacy : nil }, defaults: defaults
    )
    await service.migrateFromPreviousLabel()
    #expect(current.registrations == 1)
    #expect(legacy.unregistrations == 1)
    #expect(service.state == .requiresApproval)
    #expect(defaults.string(forKey: ChargeHelperService.registeredLabelKey) == label)

    // 已迁移过：不再注册或注销。
    await service.migrateFromPreviousLabel()
    #expect(current.registrations == 1)
    #expect(legacy.unregistrations == 1)
}

@MainActor
@Test func neverRegisteredLabelWithPlistCanBeInstalled() async {
    // 新 label 从没注册过时系统返回 notFound：plist 在包里就可以安装，升级时照常迁移。
    let current = FakeHelperRegistration()
    current.status = .notFound
    current.statusAfterRegister = .requiresApproval
    let legacy = FakeHelperRegistration()
    legacy.status = .enabled
    let service = ChargeHelperService(
        registration: current, label: "io.github.nanvon.hachibu.helper.0.1.11",
        registrationForLabel: { $0 == ChargeHelper.legacyLabel ? legacy : nil }, hasDaemonPlist: true
    )
    #expect(service.state == .notRegistered)
    await service.migrateFromPreviousLabel()
    #expect(current.registrations == 1)
    #expect(legacy.unregistrations == 1)

    // plist 不在包里：App 缺少 helper。
    let missing = FakeHelperRegistration()
    missing.status = .notFound
    #expect(ChargeHelperService(registration: missing).state == .unavailable)
}

@MainActor
@Test func upgradeUnregistersPreviousVersionedLabel() async {
    let current = FakeHelperRegistration()
    let previous = FakeHelperRegistration()
    previous.removalError = NSError(domain: "SMAppServiceErrorDomain", code: 3)
    current.statusAfterRegister = .enabled
    let defaults = UserDefaults(suiteName: "HelperMigration-\(UUID().uuidString)")!
    defaults.set("io.github.nanvon.hachibu.helper.0.1.11", forKey: ChargeHelperService.registeredLabelKey)
    let label = "io.github.nanvon.hachibu.helper.0.1.12"
    let service = ChargeHelperService(
        registration: current, label: label,
        registrationForLabel: { $0 == "io.github.nanvon.hachibu.helper.0.1.11" ? previous : nil }, defaults: defaults
    )
    await service.migrateFromPreviousLabel()
    // 旧 plist 不在包里时注销会失败，仍改用本版本。
    #expect(previous.unregistrations == 1)
    #expect(current.registrations == 1)
    #expect(defaults.string(forKey: ChargeHelperService.registeredLabelKey) == label)
}

@MainActor
@Test func noMigrationWithoutPreviousHelper() async {
    // 从没装过 helper：不自动注册。移除后清掉记录，之后也不再自动注册。
    let current = FakeHelperRegistration()
    let legacy = FakeHelperRegistration()
    let defaults = UserDefaults(suiteName: "HelperMigration-\(UUID().uuidString)")!
    let service = ChargeHelperService(
        registration: current, label: "io.github.nanvon.hachibu.helper.0.1.11",
        registrationForLabel: { _ in legacy }, defaults: defaults
    )
    await service.migrateFromPreviousLabel()
    #expect(current.registrations == 0)
    #expect(legacy.unregistrations == 0)

    current.statusAfterRegister = .enabled
    service.register()
    #expect(defaults.string(forKey: ChargeHelperService.registeredLabelKey) != nil)
    await service.unregister()
    #expect(defaults.string(forKey: ChargeHelperService.registeredLabelKey) == nil)
}

@Test func helperLaunchStateParsesLaunchctlOutput() {
    // 2026-11-09 本机 launchctl print 的原文片段。
    let failed = """
    system/io.github.nanvon.hachibu.helper = {
    \tactive count = 0
    \tstate = spawn scheduled
    \tlast exit code = 78: EX_CONFIG
    \t\tstate = active
    \tjob state = spawn failed
    }
    """
    #expect(HelperLaunchState.parse(output: failed, exitCode: 0) == .spawnFailed)

    let running = """
    system/com.apple.powerd = {
    \tstate = running
    \t\tstate = active
    \tjob state = running
    }
    """
    #expect(HelperLaunchState.parse(output: running, exitCode: 0) == .running)
    #expect(HelperLaunchState.parse(output: "\tstate = running\n", exitCode: 0) == .running)

    let missing = "Bad request.\nCould not find service \"io.github.nanvon.hachibu.helper\" in domain for system\n"
    #expect(HelperLaunchState.parse(output: missing, exitCode: 113) == .notLoaded)

    // 不认识的输出不当成连不上，照常经 XPC 检查。
    #expect(HelperLaunchState.parse(output: "\tstate = waiting\n", exitCode: 0) == .unknown)
    #expect(HelperLaunchState.parse(output: "", exitCode: 1) == .unknown)
    #expect(!HelperLaunchState.unknown.isUnreachable)
}

/// 所有写入只发生在内存假系统中，不注册 helper、不修改本机充电设置。
private final class ManagedTestSystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var state = (percent: 90, enabled: true, limit: 80, uiState: 14, fails: false)
    private var log: [ChargeLimitChange] = []
    private var policyReadFails = false
    private var overrideReadFails = false
    private var fullReadFails = false

    var writes: [ChargeLimitChange] { lock.withLock { log } }
    var setting: ChargeLimitSetting { lock.withLock { state.enabled ? .on(percent: state.limit) : .off } }

    func set(
        percent: Int? = nil, limit: Int? = nil, uiState: Int? = nil, fails: Bool? = nil,
        policyReadFails: Bool? = nil, overrideReadFails: Bool? = nil, fullReadFails: Bool? = nil
    ) {
        lock.withLock {
            if let percent { state.percent = percent }
            if let limit { state.limit = limit; state.enabled = limit < 100 }
            if let uiState { state.uiState = uiState }
            if let fails { state.fails = fails }
            if let policyReadFails { self.policyReadFails = policyReadFails }
            if let overrideReadFails { self.overrideReadFails = overrideReadFails }
            if let fullReadFails { self.fullReadFails = fullReadFails }
        }
    }

    func read() throws -> RawBatteryReadings {
        try lock.withLock {
            guard !fullReadFails else { throw BatteryDataSourceError.powerSourcesUnavailable }
            return RawBatteryReadings(
                powerSources: [[
                    "Type": .string("InternalBattery"), "Current Capacity": .int(Int64(state.percent)),
                    "Max Capacity": .int(100), "Power Source State": .string("AC Power"), "Is Charging": .bool(false),
                ]],
                smartBattery: nil, smartBatteryPack: nil, adapterDetails: nil, chargeLimitArchive: nil,
                powerUIChargeLimit: PowerUIChargeLimit(
                    isSupported: true, isEnabled: state.enabled, limit: state.limit,
                    availableLimits: [80, 85, 90, 95, 100], uiState: policyReadFails ? nil : state.uiState
                ), fullChargeOverrideActive: overrideReadFails ? nil : false, lowPowerModeEnabled: false
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

private final class PausedChargeLimitWriter: ChargeLimitWriter, Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)
    private let system: ManagedTestSystem

    init(system: ManagedTestSystem) {
        self.system = system
        (started, signal) = AsyncStream.makeStream()
    }

    func write(_ change: ChargeLimitChange) throws {
        if change == .limit(90) {
            signal.yield(())
            guard gate.wait(timeout: .now() + 5) == .success else {
                throw ChargeLimitWriteError(message: "test write was not resumed")
            }
        }
        try system.write(change)
    }

    func resume() { gate.signal() }
}

@MainActor
@Suite struct ChargeControlMonitorTests {
    private let defaults = UserDefaults(suiteName: "ChargeControlMonitorTests.\(UUID().uuidString)")!
    private let system = ManagedTestSystem()

    private func monitor(store: HistoryStore? = nil, writer: (any ChargeLimitWriter)? = nil) -> BatteryMonitor {
        BatteryMonitor(
            sampler: BatterySampler(dataSource: system, systemProfiler: ManagedTestProfiler(), chargeLimitWriter: writer ?? system, store: store),
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

    @Test func removingHelperDefersAutomaticWritesUntilRemovalFinishes() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 80)
        await monitor.read()
        await settle(monitor)
        let existingWrites = system.writes.count
        monitor.isRemovingChargeHelper = true
        monitor.chargeControl.target = 90
        await monitor.read()
        #expect(system.writes.count == existingWrites)
        monitor.isRemovingChargeHelper = false
        monitor.publishChargeControl()
        await settle(monitor)
        #expect(system.setting == .on(percent: 90))
    }

    @Test func failedHelperRemovalDoesNotCancelCalibration() async {
        let backend = FakeHelperRegistration()
        backend.status = .requiresApproval
        backend.removalError = NSError(domain: "test", code: 1)
        backend.statusOnRemovalError = .notRegistered
        let helper = ChargeHelperService(registration: backend)
        let monitor = BatteryMonitor(
            sampler: BatterySampler(dataSource: system, systemProfiler: ManagedTestProfiler(), chargeLimitWriter: system, store: nil),
            powerSourceReader: { nil }, smcReader: { _ in nil }, holdDefaults: defaults, helperService: helper
        )
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 80)
        await monitor.read()
        await settle(monitor)
        monitor.calibration = CalibrationProgress(start: .manual, step: .holdFull, at: Date(), percent: 100)
        let removed = await monitor.removeChargeHelper()
        #expect(!removed)
        #expect(monitor.calibration != nil)
        #expect(!monitor.isRemovingChargeHelper)
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

    @Test(arguments: [true, false])
    func quitWaitsForChargeLimitWriteBeforeRestoringOriginal(isManaged: Bool) async {
        let writer = PausedChargeLimitWriter(system: system)
        let monitor = monitor(writer: writer)
        if isManaged {
            monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 90)
        } else {
            monitor.holdsChargeAboveLimit = true
        }
        await monitor.read()
        var started = writer.started.makeAsyncIterator()
        _ = await started.next()
        let quit = Task { await monitor.prepareToQuit() }
        while !monitor.isPreparingToQuit {
            await Task.yield()
        }
        // 90% 的写入还没生效，当前仍是 80%。这时不能清除恢复记录。
        #expect(system.setting == .on(percent: 80))
        #expect(isManaged ? monitor.managedOriginal == .on(percent: 80) : monitor.chargeLimitHold != nil)
        writer.resume()
        await quit.value
        #expect(system.writes == [.limit(90), .limit(80)])
        #expect(system.setting == .on(percent: 80))
        #expect(monitor.managedOriginal == nil)
        #expect(monitor.chargeLimitHold == nil)
    }

    @Test func systemPolicyPreventsWritesAndEndReappliesTarget() async {
        system.set(uiState: 18)
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        monitor.holdsChargeAboveLimit = true
        await monitor.read()
        await settle(monitor)
        #expect(system.writes.isEmpty)
        system.set(uiState: 14)
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

    @Test func unknownSystemPolicyDefersManagedWriteUntilBothReadsRecover() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        system.set(policyReadFails: true)
        await monitor.read()
        #expect(system.writes.isEmpty)

        system.set(uiState: 42, policyReadFails: false)
        await monitor.read()
        #expect(system.writes.isEmpty)

        system.set(uiState: 0)
        await monitor.read()
        #expect(system.writes.isEmpty)

        system.set(uiState: 14, overrideReadFails: true)
        await monitor.read()
        #expect(system.writes.isEmpty)

        system.set(overrideReadFails: false)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(85)])
    }

    @Test func fullReadFailurePreventsControlFromUsingOldPolicy() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 80)
        await monitor.read()
        let previous = monitor.reading

        system.set(uiState: 3, fullReadFails: true)
        await monitor.read()
        monitor.chargeControl.target = 85
        await monitor.refreshSMC(.display)
        await settle(monitor)
        #expect(monitor.reading == previous)
        #expect(system.writes.isEmpty)

        system.set(uiState: 14, fullReadFails: false)
        await monitor.read()
        await settle(monitor)
        #expect(system.writes == [.limit(85)])
    }

    @Test func unknownReadingDoesNotEndSystemFullChargeOrStartCalibration() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(
            mode: .managed, continuesCalibrationAfterSystemFullCharge: true
        )
        system.set(percent: 100, uiState: 18)
        await monitor.read()
        #expect(monitor.policyPeriods[.systemCalibration] != nil)

        system.set(policyReadFails: true)
        await monitor.read()
        #expect(monitor.policyPeriods[.systemCalibration] != nil)
        #expect(monitor.calibration == nil)

        system.set(uiState: 14, policyReadFails: false, overrideReadFails: true)
        await monitor.read()
        #expect(monitor.calibration == nil)

        system.set(overrideReadFails: false)
        await monitor.read()
        #expect(monitor.calibration?.step == .dischargeToLow)
    }

    @Test func cancellingCalibrationCanRestoreItsLowLimitWithUnknownPolicy() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        await monitor.read()
        await settle(monitor)
        monitor.calibration = CalibrationProgress(start: .manual, step: .dischargeToLow, at: Date(), percent: 90)
        monitor.managedAppliedLimit = CalibrationStep.dischargeTarget
        system.set(limit: CalibrationStep.dischargeTarget, policyReadFails: true)
        await monitor.read()
        #expect(system.setting == .on(percent: 15))
        #expect(monitor.calibration?.pauseReason == nil)

        monitor.cancelCalibration()
        await settle(monitor)
        #expect(system.setting == .on(percent: 85))
    }

    @Test func pausingCalibrationCanRestoreItsLowLimitWithUnknownPolicy() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 85)
        await monitor.read()
        await settle(monitor)
        monitor.calibration = CalibrationProgress(start: .manual, step: .dischargeToLow, at: Date(), percent: 90)
        monitor.managedAppliedLimit = CalibrationStep.dischargeTarget
        system.set(limit: CalibrationStep.dischargeTarget, policyReadFails: true)
        await monitor.read()

        monitor.pauseCalibration()
        await settle(monitor)
        #expect(monitor.calibration?.pauseReason == .user)
        #expect(system.setting == .on(percent: 85))
    }

    @Test func leaseUsesTargetCalibrationOrMarkerDuringSystemTemporaryFullCharge() async {
        let monitor = monitor()
        monitor.chargeControl = ChargeControlConfiguration(mode: .managed, target: 60)
        system.set(limit: 100, uiState: 3)
        await monitor.read()
        let timeout = Int(ChargeHelper.leaseTimeout)
        #expect(system.setting == .off)
        #expect(monitor.helperLeaseSeconds(hasMarker: false) == timeout)

        monitor.chargeControl.target = 85
        #expect(monitor.helperLeaseSeconds(hasMarker: false) == nil)
        #expect(monitor.helperLeaseSeconds(hasMarker: true) == timeout)

        monitor.chargeControl.keepsLimitOnQuit = true
        #expect(monitor.helperLeaseSeconds(hasMarker: true) == 0)
        monitor.calibration = CalibrationProgress(start: .manual, step: .chargeToFull, at: Date(), percent: 90)
        #expect(monitor.helperLeaseSeconds(hasMarker: false) == timeout)

        monitor.isRemovingChargeHelper = true
        #expect(monitor.helperLeaseSeconds(hasMarker: true) == nil)
        monitor.chargeControl.mode = .followSystem
        monitor.isRemovingChargeHelper = false
        #expect(monitor.helperLeaseSeconds(hasMarker: true) == nil)
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
