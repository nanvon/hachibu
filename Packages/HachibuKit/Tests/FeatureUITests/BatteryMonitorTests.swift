import BatteryCore
import Foundation
import HistoryStore
import Observation
import Testing
@testable import FeatureUI

private func rawPower(external: Bool, charging: Bool = false) -> RawBatteryReadings {
    RawBatteryReadings(
        powerSources: [[
            "Type": .string("InternalBattery"),
            "Current Capacity": .int(80), "Max Capacity": .int(100),
            "Power Source State": .string(external ? "AC Power" : "Battery Power"),
            "Is Charging": .bool(charging),
        ]],
        smartBattery: ["PowerTelemetryData": .dictionary(["SystemLoad": .int(12000)])],
        smartBatteryPack: ["BatteryData": .dictionary(["Temperature": .int(3200)])],
        adapterDetails: external ? ["Watts": .int(140)] : nil,
        chargeLimitArchive: nil, lowPowerModeEnabled: false
    )
}

private final class BlockedChargeLimitWriter: ChargeLimitWriter, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    var isBlocked: Bool { lock.withLock { blocked } }

    init() { (started, continuation) = AsyncStream.makeStream() }

    func write(_ change: ChargeLimitChange) throws {
        lock.withLock { blocked = true }
        continuation.yield(())
        _ = gate.wait(timeout: .now() + 5)
        lock.withLock { blocked = false }
    }

    func release() { gate.signal() }
}

@Suite struct BatterySamplerConcurrencyTests {
    @Test func samplingAndMinuteStorageContinueWhileChargeWriteWaits() async throws {
        let writer = BlockedChargeLimitWriter()
        defer { writer.release() }
        let store = try HistoryStore.inMemory()
        let sampler = BatterySampler(
            dataSource: FixedBatterySource(raw: rawPower(external: true)),
            systemProfiler: UnusedProfiler(), chargeLimitWriter: writer, store: store
        )
        let write = Task { await sampler.writeChargeLimit(.enable) }
        var started = writer.started.makeAsyncIterator()
        _ = await started.next()
        let reading = await sampler.read()
        let date = Date()
        await sampler.writeMinuteSample(at: date)
        let samples = try await store.minuteSamples(from: date.addingTimeInterval(-60), to: date.addingTimeInterval(60))
        #expect(writer.isBlocked)
        guard case .battery(let snapshot)? = reading.reading else {
            Issue.record("Battery missing")
            return
        }
        #expect(snapshot.systemLoadMW == 12000)
        #expect(samples.count == 1)
        writer.release()
        _ = await write.value
    }
}

private struct FixedBatterySource: BatteryDataSource {
    let raw: RawBatteryReadings
    func read() -> RawBatteryReadings { raw }
}

private struct UnusedProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}

private final class FailableBatterySource: BatteryDataSource, @unchecked Sendable {
    private let lock = NSLock()
    private var raw: RawBatteryReadings?

    init(_ raw: RawBatteryReadings?) { self.raw = raw }
    func set(_ raw: RawBatteryReadings?) { lock.withLock { self.raw = raw } }
    func read() throws -> RawBatteryReadings {
        try lock.withLock {
            guard let raw else { throw BatteryDataSourceError.powerSourcesUnavailable }
            return raw
        }
    }
}

/// 模拟完整采样卡在慢接口；由测试显式释放，不依赖真实硬件和运行循环。
private final class BlockedBatterySource: BatteryDataSource, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let gate = DispatchSemaphore(value: 0)
    private let raw: RawBatteryReadings
    private let lock = NSLock()
    private var hasRead = false
    private var blocked = false

    var isBlocked: Bool { lock.withLock { blocked } }

    init(raw: RawBatteryReadings) {
        self.raw = raw
        (started, continuation) = AsyncStream.makeStream()
    }

    func read() -> RawBatteryReadings {
        let shouldBlock = lock.withLock {
            let first = !hasRead
            hasRead = true
            if first { blocked = true }
            return first
        }
        continuation.yield(())
        // 失败时也释放测试线程，避免整个测试进程永久挂起。
        if shouldBlock {
            _ = gate.wait(timeout: .now() + 10)
            lock.withLock { blocked = false }
        }
        return raw
    }

    func release() { gate.signal() }
}

private final class PowerStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BatteryReading?
    init(_ value: BatteryReading?) { self.value = value }
    func read() -> BatteryReading? { lock.withLock { value } }
    func set(_ value: BatteryReading?) { lock.withLock { self.value = value } }
}

/// 第一笔快速读取延迟返回，第二笔先完成，模拟连续插拔时返回乱序。
private final class ReorderedPowerSource: @unchecked Sendable {
    let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var isFirst = true
    private let gate = DispatchSemaphore(value: 0)

    init() { (started, continuation) = AsyncStream.makeStream() }

    func read() -> BatteryReading? {
        let first = lock.withLock { let first = isFirst; isFirst = false; return first }
        if first {
            continuation.yield(())
            _ = gate.wait(timeout: .now() + 10)
        }
        return .battery(BatterySnapshot(percent: 80, isExternalPower: first, isCharging: false))
    }

    func release() { gate.signal() }
}

@MainActor
@Suite struct BatteryMonitorTests {
    private func monitor(
        source: any BatteryDataSource,
        power: @escaping @Sendable () -> BatteryReading?,
        smc: @escaping @Sendable (SMCReadScope) -> SMCReadings? = { _ in nil }
    ) -> BatteryMonitor {
        BatteryMonitor(
            sampler: BatterySampler(dataSource: source, systemProfiler: UnusedProfiler(), chargeLimitWriter: nil, store: nil),
            powerSourceReader: power,
            smcReader: smc
        )
    }

    @Test func powerStateUpdatesWhileFullReadIsBlockedAndSurvivesItsOldResult() async throws {
        let source = BlockedBatterySource(raw: rawPower(external: false))
        defer { source.release() }
        let power = PowerStateBox(.battery(BatterySnapshot(percent: 80, isExternalPower: true, isCharging: false)))
        let monitor = monitor(source: source, power: { power.read() })
        let fullRead = Task { await monitor.read() }
        var started = source.started.makeAsyncIterator()
        _ = await started.next()

        await monitor.refreshPowerSource()
        guard case .battery(let fast) = monitor.reading else { Issue.record("Quick state did not reach UI"); return }
        #expect(fast.isExternalPower == true)
        #expect(fast.systemLoadMW == nil)

        source.release()
        await fullRead.value
        guard case .battery(let complete) = monitor.reading else { Issue.record("Full state missing"); return }
        #expect(complete.isExternalPower == true)
        #expect(complete.isCharging == false)
        #expect(complete.systemLoadMW == 12000)
        #expect(complete.temperatureCelsius == 32)
    }

    @Test func quickUnplugPreservesTelemetryAndDoesNotRepeatAlerts() async throws {
        let power = PowerStateBox(.battery(BatterySnapshot(percent: 79, isExternalPower: false, isCharging: false)))
        let monitor = monitor(source: FixedBatterySource(raw: rawPower(external: true)), power: { power.read() })
        var alertReads = 0
        monitor.onRead = { _, _ in alertReads += 1 }
        await monitor.read()
        await monitor.refreshPowerSource()

        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isExternalPower == false)
        #expect(snapshot.percent == 79)
        #expect(snapshot.adapter == nil)
        #expect(snapshot.systemLoadMW == 12000)
        #expect(snapshot.temperatureCelsius == 32)
        #expect(alertReads == 1)
    }

    @Test func secondRefreshEventUpdatesUIBeforePendingFullReadFinishes() async {
        let source = BlockedBatterySource(raw: rawPower(external: false))
        defer { source.release() }
        let power = PowerStateBox(.battery(BatterySnapshot(percent: 80, isExternalPower: false, isCharging: false)))
        let monitor = monitor(source: source, power: { power.read() })
        monitor.readNow()
        var started = source.started.makeAsyncIterator()
        _ = await started.next()

        let (updates, continuation) = AsyncStream<BatteryReading?>.makeStream()
        withObservationTracking {
            _ = monitor.reading
        } onChange: {
            Task { @MainActor in continuation.yield(monitor.reading) }
        }
        power.set(.battery(BatterySnapshot(percent: 80, isExternalPower: true, isCharging: true)))
        monitor.readNow()
        var iterator = updates.makeAsyncIterator()
        _ = await iterator.next()

        #expect(source.isBlocked)
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isExternalPower == true)
        #expect(snapshot.isCharging == true)
    }

    @Test func lateQuickReadCannotUndoNewerQuickRead() async {
        let source = ReorderedPowerSource()
        defer { source.release() }
        let monitor = monitor(source: FixedBatterySource(raw: rawPower(external: true)), power: { source.read() })
        let oldRead = Task { await monitor.refreshPowerSource() }
        var started = source.started.makeAsyncIterator()
        _ = await started.next()
        await monitor.refreshPowerSource()
        source.release()
        await oldRead.value
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isExternalPower == false)
    }

    @Test func lateQuickReadCannotUndoNewerFullRead() async {
        let source = ReorderedPowerSource()
        defer { source.release() }
        let monitor = monitor(source: FixedBatterySource(raw: rawPower(external: false)), power: { source.read() })
        let oldRead = Task { await monitor.refreshPowerSource() }
        var started = source.started.makeAsyncIterator()
        _ = await started.next()
        await monitor.read()
        source.release()
        await oldRead.value
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isExternalPower == false)
        #expect(snapshot.systemLoadMW == 12000)
    }

    @Test func newerFullReadCanReplaceOlderQuickState() async {
        let monitor = monitor(
            source: FixedBatterySource(raw: rawPower(external: true, charging: true)),
            power: { .battery(BatterySnapshot(percent: 80, isExternalPower: false, isCharging: false)) }
        )
        await monitor.refreshPowerSource()
        await monitor.read()
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isExternalPower == true)
        #expect(snapshot.isCharging == true)
    }

    @Test func quickFailurePreservesStateAndNoBatteryIsDistinct() async {
        let power = PowerStateBox(nil)
        let monitor = monitor(source: FixedBatterySource(raw: rawPower(external: true)), power: { power.read() })
        await monitor.read()
        let previous = monitor.reading
        await monitor.refreshPowerSource()
        #expect(monitor.reading == previous)
        power.set(.noBattery)
        await monitor.refreshPowerSource()
        #expect(monitor.reading == .noBattery)
    }

    @Test func fullFailurePreservesQuickStateAndDoesNotWriteOldSamples() async throws {
        let source = FailableBatterySource(rawPower(external: true))
        let store = try HistoryStore.inMemory()
        let sampler = BatterySampler(dataSource: source, systemProfiler: UnusedProfiler(), chargeLimitWriter: nil, store: store)
        let monitor = BatteryMonitor(sampler: sampler, powerSourceReader: {
            .battery(BatterySnapshot(percent: 79, isExternalPower: false, isCharging: false))
        }, smcReader: { _ in nil })
        var failures = 0
        monitor.onRead = { reading, _ in if reading == nil { failures += 1 } }
        await monitor.read()
        await monitor.refreshPowerSource()
        let previous = monitor.reading
        source.set(nil)
        await monitor.read()
        #expect(monitor.reading == previous)
        #expect(failures == 1)

        let now = Date()
        await sampler.writeMinuteSample(at: now)
        #expect(try await store.minuteSamples(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)).isEmpty)
        source.set(rawPower(external: false))
        await monitor.read()
        await sampler.writeMinuteSample(at: now)
        #expect(try await store.minuteSamples(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60)).count == 1)
    }

    @Test func fullFailureAtStartupIsDistinctFromConfirmedNoBattery() async {
        let source = FailableBatterySource(nil)
        let monitor = monitor(source: source, power: { nil })
        await monitor.read()
        #expect(monitor.reading == nil)
        var noBattery = rawPower(external: false)
        noBattery.powerSources = []
        source.set(noBattery)
        await monitor.read()
        #expect(monitor.reading == .noBattery)
    }

    // MARK: - SMC（docs/v1技术设计.md 5.1）

    @Test func smcOverlaysEachReadableKeyAndKeepsOthers() async {
        let smc = SMCBox(SMCReadings(isCharging: true, batteryPowerMW: 30000, powerInMW: 45000))
        let monitor = monitor(
            source: FixedBatterySource(raw: rawPower(external: true)),
            power: { nil }, smc: { smc.read($0) }
        )
        await monitor.read()
        await monitor.refreshSMC(.display)
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isCharging == true)
        #expect(snapshot.batteryPowerMW == 30000)
        #expect(snapshot.powerInMW == 45000)
        // PSTR、TB0T 读不到时退回 IORegistry。
        #expect(snapshot.systemLoadMW == 12000)
        #expect(snapshot.temperatureCelsius == 32)
        #expect(ChargeStatus(snapshot) == .charging)
    }

    @Test func smcFailureFallsBackToRegistry() async {
        let smc = SMCBox(SMCReadings(isCharging: true, systemPowerMW: 20000))
        let monitor = monitor(
            source: FixedBatterySource(raw: rawPower(external: true)),
            power: { nil }, smc: { smc.read($0) }
        )
        await monitor.read()
        await monitor.refreshSMC(.display)
        smc.set(nil)
        await monitor.refreshSMC(.display)
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isCharging == false)
        #expect(snapshot.systemLoadMW == 12000)
    }

    @Test func newerChargingReadOverridesOlderDisplayRead() async {
        let smc = SMCBox(SMCReadings(isCharging: false, batteryPowerMW: 0))
        let monitor = monitor(
            source: FixedBatterySource(raw: rawPower(external: true)),
            power: { nil }, smc: { smc.read($0) }
        )
        await monitor.read()
        await monitor.refreshSMC(.display)
        smc.set(SMCReadings(isCharging: true))
        await monitor.refreshSMC(.charging)
        guard case .battery(let charging) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(charging.isCharging == true)
        // 功率仍取较早的全部 key 读数，等待下一次读取。
        #expect(charging.batteryPowerMW == 0)

        smc.set(SMCReadings(isCharging: false, batteryPowerMW: -100))
        await monitor.refreshSMC(.display)
        guard case .battery(let stopped) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(stopped.isCharging == false)
    }

    @Test func smcUpdatesWhileFullReadIsBlocked() async {
        let source = BlockedBatterySource(raw: rawPower(external: true))
        defer { source.release() }
        let smc = SMCBox(SMCReadings(isCharging: true))
        let monitor = monitor(
            source: source,
            power: { .battery(BatterySnapshot(percent: 80, isExternalPower: true, isCharging: false)) },
            smc: { smc.read($0) }
        )
        await monitor.refreshPowerSource()
        let fullRead = Task { await monitor.read() }
        var started = source.started.makeAsyncIterator()
        _ = await started.next()

        await monitor.refreshSMC(.charging)
        #expect(source.isBlocked)
        guard case .battery(let snapshot) = monitor.reading else { Issue.record("Battery missing"); return }
        #expect(snapshot.isCharging == true)
        source.release()
        await fullRead.value
    }

    @Test func minuteSamplesKeepRegistryValues() async throws {
        let store = try HistoryStore.inMemory()
        let sampler = BatterySampler(
            dataSource: FixedBatterySource(raw: rawPower(external: true)),
            systemProfiler: UnusedProfiler(), chargeLimitWriter: nil, store: store
        )
        let monitor = BatteryMonitor(
            sampler: sampler, powerSourceReader: { nil },
            smcReader: { _ in SMCReadings(isCharging: true, systemPowerMW: 20000) }
        )
        await monitor.read()
        await monitor.refreshSMC(.display)
        let now = Date()
        await sampler.writeMinuteSample(at: now)
        let samples = try await store.minuteSamples(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        #expect(samples.first?.systemLoadMW == 12000)
        #expect(samples.first?.isCharging == false)
    }
}

private final class SMCBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SMCReadings?
    init(_ value: SMCReadings?) { self.value = value }
    func read(_ scope: SMCReadScope) -> SMCReadings? {
        lock.withLock {
            guard let value else { return nil }
            return scope == .charging ? SMCReadings(isCharging: value.isCharging) : value
        }
    }
    func set(_ value: SMCReadings?) { lock.withLock { self.value = value } }
}
