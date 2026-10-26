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

    @Test func healthAlertFollowsThreshold() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)

            await monitor.handleHealth(BatteryHealthInfo(systemMaximumCapacityPercent: 79, condition: nil))
            #expect(await notifier.firstDelivered() == .lowHealth(maximumCapacityPercent: 79, threshold: 80))
            #expect(monitor.healthStatus == .alerted)

            settings.healthAlertThreshold = 75
            #expect(monitor.healthStatus == .waiting)

            let reloaded = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            settings.healthAlertThreshold = 80
            #expect(reloaded.healthStatus == .alerted)
        }
    }

    @Test func failedHealthDeliveryIsRetriedAndOnlySuccessIsPersisted() async {
        await withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            let notifier = FakeNotifier(status: .allowed)
            await notifier.failNextDelivery()
            let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            let health = BatteryHealthInfo(systemMaximumCapacityPercent: 79, condition: nil)

            await monitor.handleHealth(health)
            #expect(monitor.healthStatus == .waiting)
            #expect(defaults.object(forKey: "healthAlertedThreshold") == nil)
            #expect(await notifier.attempts.count == 1)
            let reloaded = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            #expect(reloaded.healthStatus == .waiting)

            await reloaded.handleHealth(health)
            #expect(reloaded.healthStatus == .alerted)
            #expect(defaults.integer(forKey: "healthAlertedThreshold") == 80)
            #expect(await notifier.attempts.count == 2)
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
}

/// 由测试明确完成发送，检查等待期间不会提前持久化或重复发送。
private actor PausedNotifier: AlertNotifier {
    private let started: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var completion: CheckedContinuation<Void, Never>?
    private(set) var attempts = 0

    init() { (started, continuation) = AsyncStream.makeStream() }
    func authorization() async -> NotificationAuthorization { .allowed }
    func requestAuthorization() async -> NotificationAuthorization { .allowed }
    func deliver(_ alert: BatteryAlert) async {
        attempts += 1
        await withCheckedContinuation { completion in
            self.completion = completion
            continuation.yield(())
        }
    }
    func waitUntilStarted() async {
        for await _ in started { return }
    }
    func accept() { completion?.resume(); completion = nil }
}

@MainActor
@Suite struct PendingAlertDeliveryTests {
    @Test func concurrentHealthReadingsWaitForOneAcceptedDelivery() async {
        let suite = "PendingAlertDeliveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let notifier = PausedNotifier()
        let monitor = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
        let health = BatteryHealthInfo(systemMaximumCapacityPercent: 79, condition: nil)
        let sending = Task { await monitor.handleHealth(health) }
        await notifier.waitUntilStarted()
        #expect(monitor.healthStatus == .waiting)
        #expect(defaults.object(forKey: "healthAlertedThreshold") == nil)
        await monitor.handleHealth(health)
        #expect(await notifier.attempts == 1)
        await notifier.accept()
        await sending.value
        #expect(monitor.healthStatus == .alerted)
        #expect(defaults.integer(forKey: "healthAlertedThreshold") == 80)
    }
}
