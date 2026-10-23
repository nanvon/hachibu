import BatteryCore
import Foundation
import Testing
@testable import FeatureUI

/// 记录要发出的提醒，不调用系统通知中心。
private final class FakeNotifier: AlertNotifier {
    let status: NotificationAuthorization
    let delivered: AsyncStream<BatteryAlert>
    private let continuation: AsyncStream<BatteryAlert>.Continuation

    init(status: NotificationAuthorization) {
        self.status = status
        (delivered, continuation) = AsyncStream.makeStream()
    }

    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> NotificationAuthorization { status }
    func deliver(_ alert: BatteryAlert) async { continuation.yield(alert) }

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

    private func feedTemperature(_ monitor: AlertMonitor, _ celsius: Double, count: Int) {
        for index in 0..<count {
            monitor.handleReading(
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

            feedTemperature(monitor, 41, count: 4)
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

            feedTemperature(monitor, 45, count: 10)
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

            feedTemperature(monitor, 45, count: 10)
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

            monitor.handleHealth(BatteryHealthInfo(systemMaximumCapacityPercent: 79, condition: nil))
            #expect(await notifier.firstDelivered() == .lowHealth(maximumCapacityPercent: 79, threshold: 80))
            #expect(monitor.healthStatus == .alerted)

            settings.healthAlertThreshold = 75
            #expect(monitor.healthStatus == .waiting)

            let reloaded = AlertMonitor(settings: settings, notifier: notifier, defaults: defaults)
            settings.healthAlertThreshold = 80
            #expect(reloaded.healthStatus == .alerted)
        }
    }
}
