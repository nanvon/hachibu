import BatteryCore
import Foundation
import Testing
@testable import FeatureUI

@Suite struct ChargeLimitControlTests {
    private let options = [80, 85, 90, 95, 100]

    private func snapshot(_ chargeLimit: ChargeLimitSetting?, options: [Int]? = [80, 85, 90, 95, 100]) -> BatterySnapshot {
        BatterySnapshot(chargeLimit: chargeLimit, chargeLimitOptions: options)
    }

    @Test func availableWhenWritableAndKnown() throws {
        let on = try #require(ChargeLimitControl(snapshot: snapshot(.on(percent: 85)), canWrite: true, isBlocked: false))
        #expect(on.isEnabled)
        #expect(on.percent == 85)
        #expect(on.options == options)
        #expect(on.isInteractive)

        let off = try #require(ChargeLimitControl(snapshot: snapshot(.off), canWrite: true, isBlocked: false))
        #expect(!off.isEnabled)
        #expect(off.percent == nil)
    }

    @Test func unavailableWithoutWriterOptionsOrKnownSetting() {
        #expect(ChargeLimitControl(snapshot: snapshot(.on(percent: 80)), canWrite: false, isBlocked: false) == nil)
        #expect(ChargeLimitControl(snapshot: snapshot(.on(percent: 80), options: nil), canWrite: true, isBlocked: false) == nil)
        #expect(ChargeLimitControl(snapshot: snapshot(.unsupported), canWrite: true, isBlocked: false) == nil)
        #expect(ChargeLimitControl(snapshot: snapshot(nil), canWrite: true, isBlocked: false) == nil)
    }

    @Test func samplerReportsAppliedOnlyWhenReadBackMatches() async {
        let system = FakeChargeLimitSystem()
        let sampler = BatterySampler(dataSource: system, systemProfiler: NoProfiler(), chargeLimitWriter: system, store: nil)
        #expect(sampler.canWriteChargeLimit)

        let lowered = await sampler.writeChargeLimit(.limit(85))
        #expect(lowered.applied)
        #expect(lowered.reading.chargeLimit == .on(percent: 85))

        #expect(await sampler.writeChargeLimit(.disable).applied)

        system.ignoresWrites = true
        #expect(await !sampler.writeChargeLimit(.enable).applied)

        system.ignoresWrites = false
        system.failsWrites = true
        #expect(await !sampler.writeChargeLimit(.enable).applied)
    }

    @Test func samplerWithoutWriterCannotWrite() async {
        let sampler = BatterySampler(dataSource: FakeChargeLimitSystem(), systemProfiler: NoProfiler(), chargeLimitWriter: nil, store: nil)
        #expect(!sampler.canWriteChargeLimit)
        #expect(await !sampler.writeChargeLimit(.disable).applied)
    }

    @Test func notInteractiveWhileBlockedOrWriting() throws {
        let blocked = try #require(ChargeLimitControl(snapshot: snapshot(.on(percent: 80)), canWrite: true, isBlocked: true))
        #expect(!blocked.isInteractive)
        let writing = try #require(ChargeLimitControl(
            snapshot: snapshot(.on(percent: 80)), canWrite: true, isBlocked: false, isWriting: true
        ))
        #expect(!writing.isInteractive)
    }
}

/// 模拟 PowerUI：写入后读回新的开关和上限。
private final class FakeChargeLimitSystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = true
    private var limit = 80
    /// 写入返回成功但设置不变。
    var ignoresWrites: Bool {
        get { lock.withLock { _ignoresWrites } }
        set { lock.withLock { _ignoresWrites = newValue } }
    }
    var failsWrites: Bool {
        get { lock.withLock { _failsWrites } }
        set { lock.withLock { _failsWrites = newValue } }
    }
    private var _ignoresWrites = false
    private var _failsWrites = false

    func read() -> RawBatteryReadings {
        lock.withLock {
            RawBatteryReadings(
                powerSources: [["Type": .string("InternalBattery")]],
                smartBattery: nil,
                smartBatteryPack: nil,
                adapterDetails: nil,
                chargeLimitArchive: nil,
                powerUIChargeLimit: PowerUIChargeLimit(
                    isSupported: true,
                    isEnabled: isEnabled,
                    limit: isEnabled ? limit : 100,
                    availableLimits: [80, 85, 90, 95, 100]
                ),
                lowPowerModeEnabled: false
            )
        }
    }

    func write(_ change: ChargeLimitChange) throws {
        try lock.withLock {
            if _failsWrites { throw ChargeLimitWriteError(message: "fake failure") }
            guard !_ignoresWrites else { return }
            switch change {
            case .enable: isEnabled = true
            case .disable: isEnabled = false
            case .limit(let percent): limit = percent
            }
        }
    }
}

private struct NoProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue {
        throw CocoaError(.featureUnsupported)
    }
}

private extension BatteryReading {
    var chargeLimit: ChargeLimitSetting? {
        if case .battery(let snapshot) = self { snapshot.chargeLimit } else { nil }
    }
}
