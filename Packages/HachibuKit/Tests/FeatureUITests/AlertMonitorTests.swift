import BatteryCore
import Foundation
import Testing
@testable import FeatureUI

/// 记录要发出的提醒，不调用系统通知中心。
private actor FakeNotifier: AlertNotifier {
    let status: NotificationAuthorization
    let delivered: AsyncStream<BatteryAlert>
    private let continuation: AsyncStream<BatteryAlert>.Continuation
    private var remainingFailures = 0
    private(set) var attempts: [BatteryAlert] = []

    enum Failure: Error { case rejected }

    init(status: NotificationAuthorization) {
        self.status = status
        (delivered, continuation) = AsyncStream.makeStream()
    }

    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> NotificationAuthorization { status }
    func failNextDelivery() { remainingFailures += 1 }
    func deliver(_ alert: BatteryAlert) async throws {
        attempts.append(alert)
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw Failure.rejected
        }
        continuation.yield(alert)
    }

    func firstDelivered() async -> BatteryAlert? {
        for await alert in delivered { return alert }
        return nil
    }
}

@MainActor
@Suite struct AlertMonitorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 每个测试用独立的 UserDefaults 域，结束时删除。
    private func withDefaults(_ body: (UserDefaults) async -> Void) async {
        let suiteName = "AlertMonitorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(defaults)
    }

    private func feedTemperature(_ monitor: AlertMonitor, _ celsius: Double, count: Int) async {
        for index in 0..<count {
            await monitor.handleReading(
                .battery(BatterySnapshot(temperatureCelsius: celsius)),
                at: start.addingTimeInterval(Double(index) * 60)
            )
        }
    }

    @Test func temperatureAlertIsDeliveredAndPersisted() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()

            await feedTemperature(monitor, 41, count: 4)
            #expect(monitor.temperatureStatus == .alerted)
            #expect(await notifier.firstDelivered() == .highTemperature(celsius: 41, threshold: 40))

            let reloaded = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            #expect(reloaded.temperatureStatus == .alerted)
        }
    }

    @Test func noEvaluationWithoutAuthorization() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let monitor = AlertMonitor(settings: settings, notifier: FakeNotifier(status: .denied), defaults: defaults)
            await monitor.refreshAuthorization()

            await feedTemperature(monitor, 45, count: 10)
            #expect(monitor.temperatureStatus == .waiting)
            #expect(monitor.latestTemperature == 45)
        }
    }

    @Test func disabledAlertShowsOff() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.temperatureAlertEnabled = false
            let monitor = AlertMonitor(settings: settings, notifier: FakeNotifier(status: .allowed), defaults: defaults)
            await monitor.refreshAuthorization()

            await feedTemperature(monitor, 45, count: 10)
            #expect(monitor.temperatureStatus == .off)
            settings.temperatureAlertEnabled = true
            #expect(monitor.temperatureStatus == .waiting)
        }
    }

    @Test func legacyHealthReadingDoesNotSendAlert() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.handleHealth(BatteryHealthInfo(systemMaximumCapacityPercent: 79, condition: nil))
            #expect(await notifier.attempts.isEmpty)
        }
    }

    @Test func failedTemperatureDeliveryRetriesOnNextReading() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            await notifier.failNextDelivery()
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()
            await feedTemperature(monitor, 41, count: 4)
            #expect(monitor.temperatureStatus == .waiting)
            #expect(!defaults.bool(forKey: "temperatureAlerted"))
            #expect(await notifier.attempts.count == 1)

            await monitor.handleReading(.battery(BatterySnapshot(temperatureCelsius: 41)), at: start.addingTimeInterval(240))
            #expect(monitor.temperatureStatus == .alerted)
            #expect(defaults.bool(forKey: "temperatureAlerted"))
            #expect(await notifier.attempts.count == 2)
        }
    }

    @Test func failedReadingBreaksTemperatureTiming() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()
            await feedTemperature(monitor, 41, count: 3)
            await monitor.handleReading(nil, at: start.addingTimeInterval(130))
            #expect(monitor.latestTemperature == nil)
            for second in [180.0, 240, 300] {
                await monitor.handleReading(.battery(BatterySnapshot(temperatureCelsius: 41)), at: start.addingTimeInterval(second))
            }
            #expect(monitor.temperatureStatus == .waiting)
            #expect(await notifier.attempts.isEmpty)
            await monitor.handleReading(.battery(BatterySnapshot(temperatureCelsius: 41)), at: start.addingTimeInterval(360))
            #expect(monitor.temperatureStatus == .alerted)
        }
    }

    // MARK: 充电接管通知

    private func makeChargeMonitor(_ defaults: UserDefaults, configure: (AppSettings) -> Void = { _ in }) async -> (AlertMonitor, FakeNotifier) {
        let settings = AppSettings(defaults: defaults)
        configure(settings)
        let notifier = FakeNotifier(status: .allowed)
        let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
        await monitor.refreshAuthorization()
        return (monitor, notifier)
    }

    @Test func chargeControlNoticesAreDelivered() async {
        await withDefaults { defaults in
            let (monitor, notifier) = await makeChargeMonitor(defaults) { $0.systemCalibrationAlertEnabled = true }
            await monitor.handleChargeControlNotice(.calibrationCompleted, at: start)
            await monitor.handleChargeControlNotice(.calibrationPaused(.unplugged), at: start)
            await monitor.handleChargeControlNotice(.limitNotApplied(limit: 60), at: start)
            await monitor.handleChargeControlNotice(.systemCalibrationStarted, at: start)
            #expect(await notifier.attempts == [
                .calibrationCompleted, .calibrationPaused(.unplugged), .limitNotApplied(limit: 60), .systemCalibrationStarted,
            ])
        }
    }

    @Test func chargeControlNoticesRespectSwitches() async {
        await withDefaults { defaults in
            let (monitor, notifier) = await makeChargeMonitor(defaults) {
                $0.calibrationAlertsEnabled = false
                $0.chargeLimitAlertEnabled = false
            }
            await monitor.handleChargeControlNotice(.calibrationCompleted, at: start)
            await monitor.handleChargeControlNotice(.calibrationPaused(.unplugged), at: start)
            await monitor.handleChargeControlNotice(.limitNotApplied(limit: 60), at: start)
            // 系统校准提醒默认关闭。
            await monitor.handleChargeControlNotice(.systemCalibrationStarted, at: start)
            #expect(await notifier.attempts.isEmpty)
        }
    }

    @Test func userAndSystemPolicyPausesAreNotDelivered() async {
        await withDefaults { defaults in
            let (monitor, notifier) = await makeChargeMonitor(defaults)
            await monitor.handleChargeControlNotice(.calibrationPaused(.user), at: start)
            await monitor.handleChargeControlNotice(.calibrationPaused(.systemPolicy), at: start)
            #expect(await notifier.attempts.isEmpty)
        }
    }

    @Test func chargeControlNoticesAreDeduplicatedForThirtyMinutes() async {
        await withDefaults { defaults in
            let (monitor, notifier) = await makeChargeMonitor(defaults)
            await monitor.handleChargeControlNotice(.limitNotApplied(limit: 60), at: start)
            await monitor.handleChargeControlNotice(.limitNotApplied(limit: 60), at: start.addingTimeInterval(29 * 60))
            // 不同上限、不同原因各自计时。
            await monitor.handleChargeControlNotice(.limitNotApplied(limit: 50), at: start.addingTimeInterval(60))
            await monitor.handleChargeControlNotice(.calibrationPaused(.unplugged), at: start)
            await monitor.handleChargeControlNotice(.calibrationPaused(.unplugged), at: start.addingTimeInterval(10 * 60))
            await monitor.handleChargeControlNotice(.calibrationPaused(.otherTool), at: start.addingTimeInterval(10 * 60))
            #expect(await notifier.attempts.count == 4)

            await monitor.handleChargeControlNotice(.limitNotApplied(limit: 60), at: start.addingTimeInterval(30 * 60))
            await monitor.handleChargeControlNotice(.calibrationPaused(.unplugged), at: start.addingTimeInterval(30 * 60))
            #expect(await notifier.attempts.count == 6)
        }
    }

    @Test func chargeControlNoticesNeedAuthorization() async {
        await withDefaults { defaults in
            let notifier = FakeNotifier(status: .denied)
            let monitor = AlertMonitor(settings: AppSettings(defaults: defaults), notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()
            await monitor.handleChargeControlNotice(.calibrationCompleted, at: start)
            #expect(await notifier.attempts.isEmpty)
        }
    }
    @Test func batteryLevelAlertsAreOffByDefault() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()

            await monitor.handleReading(.battery(BatterySnapshot(percent: 10, isExternalPower: false)), at: start)
            #expect(await notifier.attempts.isEmpty)
        }
    }

    @Test func lowBatteryAndChargeCompleteAreDelivered() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.lowBatteryAlertEnabled = true
            settings.chargeCompleteAlertEnabled = true
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()

            await monitor.handleReading(.battery(BatterySnapshot(percent: 20, isExternalPower: false)), at: start)
            await monitor.handleReading(.battery(BatterySnapshot(percent: 30, isExternalPower: true, isCharging: true)), at: start.addingTimeInterval(60))
            await monitor.handleReading(.battery(BatterySnapshot(percent: 100, isExternalPower: true, isCharging: false)), at: start.addingTimeInterval(120))
            // 校准期间不提醒充电完成。
            await monitor.handleReading(.battery(BatterySnapshot(percent: 100, isExternalPower: true, isCharging: false)), at: start.addingTimeInterval(180), isCalibrating: true)
            #expect(await notifier.attempts == [.lowBattery(percent: 20, threshold: 20), .chargeCompleted(limit: nil)])
        }
    }

    @Test func failedBatteryLevelDeliveryRetries() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.lowBatteryAlertEnabled = true
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            await monitor.refreshAuthorization()
            await notifier.failNextDelivery()

            await monitor.handleReading(.battery(BatterySnapshot(percent: 15, isExternalPower: false)), at: start)
            await monitor.handleReading(.battery(BatterySnapshot(percent: 15, isExternalPower: false)), at: start.addingTimeInterval(60))
            await monitor.handleReading(.battery(BatterySnapshot(percent: 15, isExternalPower: false)), at: start.addingTimeInterval(120))
            #expect(await notifier.attempts == [.lowBattery(percent: 15, threshold: 20), .lowBattery(percent: 15, threshold: 20)])
        }
    }
}
