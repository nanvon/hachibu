import AppKit
import BatteryCore
import SwiftUI

/// 通知页：系统通知授权、温度提醒的开关和阈值、当前状态。两栏布局，规则见 docs/v1技术设计.md 第 12 节、19.3。
struct NotificationsPage: View {
    @Bindable var settings: AppSettings
    let alerts: AlertMonitor
    /// 用来查最近 48 小时的最高温度；数据库不可用时为 nil。
    var history: HistoryModel?

    var body: some View {
        ScrollView {
            NotificationsPageContent(settings: settings, alerts: alerts, history: history)
        }
    }
}

/// 与页面共用的内容；渲染测试直接渲染内容，避开 ImageRenderer 无法绘制的 AppKit 滚动容器。
struct NotificationsPageContent: View {
    @Bindable var settings: AppSettings
    let alerts: AlertMonitor
    var history: HistoryModel?

    private var highestTemperature: ChartPoint? { history?.highestRecentTemperature }

    var body: some View {
        SettingsColumns {
            authorizationGroup
            SettingsGroupDivider()
            temperatureGroup
        }
        .task {
            await alerts.refreshAuthorization()
            await history?.loadHighestRecentTemperature()
        }
        // 用户可能在系统设置里改了通知权限后切回来。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await alerts.refreshAuthorization() }
        }
    }

    // MARK: 系统通知

    private var authorizationGroup: some View {
        SettingsGroup(
            Text("System Notifications", bundle: .module),
            description: Text("Alerts are checked only while notifications are allowed.", bundle: .module)
        ) {
            SettingsRow(Text("Status", bundle: .module)) {
                switch alerts.authorization {
                case .allowed: StatusPill(text: Text("Allowed", bundle: .module), tint: .green)
                case .denied: StatusPill(text: Text("Not Allowed", bundle: .module), tint: .orange)
                case .notDetermined: StatusPill(text: Text("Not Requested", bundle: .module))
                }
            }
            SettingsRowDivider()
            SettingsRow(Text("Banners and Sounds", bundle: .module)) {
                switch alerts.authorization {
                case .notDetermined:
                    Button {
                        Task { await alerts.requestAuthorization() }
                    } label: {
                        Text("Allow Notifications…", bundle: .module)
                    }
                    .settingsButtonStyle()
                case .allowed, .denied:
                    Button {
                        Self.openNotificationSettings()
                    } label: {
                        Text("Open Notification Settings…", bundle: .module)
                    }
                    .settingsButtonStyle()
                }
            }
        }
    }

    // MARK: 电池温度过高

    private var temperatureGroup: some View {
        let threshold = settings.temperatureAlertThreshold
        return SettingsGroup(
            Text("High Battery Temperature", bundle: .module),
            description: Text("Alerts once after the temperature stays above \(threshold) °C for 3 minutes. Can alert again after the temperature stays below \(threshold - 2) °C for 5 minutes. The panel marks the temperature as High at or above the threshold.", bundle: .module)
        ) {
            NotificationPreview(
                title: Text("Battery Temperature High", bundle: .module),
                message: Text("The battery has stayed above \(threshold) °C for 3 minutes. Current temperature: \(DisplayFormat.celsius(Double(threshold) + 1.2)).", bundle: .module)
            )
        } panel: {
            SettingsRow(Text("Alert", bundle: .module)) {
                SettingsSwitch(isOn: $settings.temperatureAlertEnabled, label: Text("High Battery Temperature", bundle: .module))
            }
            SettingsRowDivider()
            SettingsRow(Text("Threshold", bundle: .module)) {
                SettingsStepper(
                    value: $settings.temperatureAlertThreshold,
                    range: AppSettings.temperatureThresholdRange,
                    text: "\(threshold) °C",
                    label: Text("Threshold", bundle: .module)
                )
            }
            .disabled(!settings.temperatureAlertEnabled)
            SettingsRowDivider()
            SettingsRow(Text("Current Temperature", bundle: .module)) {
                Text(verbatim: DisplayFormat.celsius(alerts.latestTemperature))
            }
            SettingsRowDivider()
            SettingsRow(Text("Highest in Last 48 Hours", bundle: .module)) {
                HStack(spacing: 6) {
                    Text(verbatim: DisplayFormat.celsius(highestTemperature?.value))
                    if let date = highestTemperature?.date {
                        Text(verbatim: date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsRowDivider()
            SettingsRow(Text("Status", bundle: .module)) {
                AlertStatusPill(status: alerts.temperatureStatus)
            }
        }
    }

    private static func openNotificationSettings() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// 提醒状态：关闭为灰色，监测中为绿色，已提醒为橙色。
private struct AlertStatusPill: View {
    let status: AlertStatus

    var body: some View {
        switch status {
        case .off: StatusPill(text: Text("Off", bundle: .module))
        case .waiting: StatusPill(text: Text("Monitoring", bundle: .module), tint: .green)
        case .alerted: StatusPill(text: Text("Alerted", bundle: .module), tint: .orange)
        }
    }
}

// MARK: - 预览

#if DEBUG
/// 固定返回给定的授权状态，不发送通知。
private struct PreviewNotifier: AlertNotifier {
    let status: NotificationAuthorization
    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> NotificationAuthorization { status }
    func deliver(_ alert: BatteryAlert) async {}
}

/// 设置和提醒状态存在独立的 UserDefaults，不影响 App 本身的设置。
private struct NotificationsPreview: View {
    @State private var settings: AppSettings
    @State private var alerts: AlertMonitor

    init(authorization: NotificationAuthorization, temperatureAlerted: Bool = false) {
        let defaults = UserDefaults(suiteName: "HachibuPreview.Notifications")!
        defaults.removePersistentDomain(forName: "HachibuPreview.Notifications")
        // 键名与 AlertMonitor 保存提醒状态的键相同。
        defaults.set(temperatureAlerted, forKey: "temperatureAlerted")
        let settings = AppSettings(defaults: defaults)
        let alerts = AlertMonitor(settings: settings, notifier: PreviewNotifier(status: authorization), defaults: defaults)
        Task {
            await alerts.handleReading(.battery(BatterySnapshot(temperatureCelsius: temperatureAlerted ? 41.2 : 31.5)), at: Date())
        }
        _settings = State(initialValue: settings)
        _alerts = State(initialValue: alerts)
    }

    var body: some View {
        NotificationsPage(settings: settings, alerts: alerts)
            .frame(width: 720, height: 660)
    }
}

#Preview("Allowed") {
    NotificationsPreview(authorization: .allowed)
}

#Preview("Temperature Alerted") {
    NotificationsPreview(authorization: .allowed, temperatureAlerted: true)
}

#Preview("Not Requested") {
    NotificationsPreview(authorization: .notDetermined)
}

#Preview("Denied") {
    NotificationsPreview(authorization: .denied)
}
#endif
