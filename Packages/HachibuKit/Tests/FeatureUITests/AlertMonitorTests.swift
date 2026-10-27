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
}
