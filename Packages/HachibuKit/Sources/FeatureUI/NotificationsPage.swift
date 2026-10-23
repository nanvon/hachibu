import AppKit
import SwiftUI

/// 通知页：系统通知授权、两种提醒的开关和阈值、当前状态。规则见 docs/v1技术设计.md 第 12 节。
struct NotificationsPage: View {
    @Bindable var settings: AppSettings
    let alerts: AlertMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications", bundle: .module)
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)

            Form {
                authorizationSection
                temperatureSection
                healthSection
            }
            .formStyle(.grouped)
        }
        .task { await alerts.refreshAuthorization() }
        // 用户可能在系统设置里改了通知权限后切回来。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await alerts.refreshAuthorization() }
        }
    }

    private var authorizationSection: some View {
        Section {
            LabeledContent {
                switch alerts.authorization {
                case .allowed: Text("Allowed", bundle: .module)
                case .denied: Text("Not Allowed", bundle: .module)
                case .notDetermined: Text("Not Requested", bundle: .module)
                }
            } label: {
                Text("System Notifications", bundle: .module)
            }
            switch alerts.authorization {
            case .allowed:
                EmptyView()
            case .notDetermined:
                Button {
                    Task { await alerts.requestAuthorization() }
                } label: {
                    Text("Allow Notifications…", bundle: .module)
                }
            case .denied:
                Button {
                    Self.openNotificationSettings()
                } label: {
                    Text("Open Notification Settings…", bundle: .module)
                }
            }
        } footer: {
            if alerts.authorization != .allowed {
                Text("Alerts are checked only while notifications are allowed.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var temperatureSection: some View {
        Section {
            Toggle(isOn: $settings.temperatureAlertEnabled) {
                Text("High Battery Temperature", bundle: .module)
            }
            Stepper(value: $settings.temperatureAlertThreshold, in: AppSettings.temperatureThresholdRange) {
                Text("Temperature above \(settings.temperatureAlertThreshold) °C", bundle: .module)
                    .monospacedDigit()
            }
            .disabled(!settings.temperatureAlertEnabled)
            LabeledContent {
                Text(verbatim: DisplayFormat.celsius(alerts.latestTemperature))
                    .monospacedDigit()
            } label: {
                Text("Current Temperature", bundle: .module)
            }
            AlertStatusRow(status: alerts.temperatureStatus)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                switch alerts.temperatureStatus {
                case .off:
                    EmptyView()
                case .waiting:
                    Text("Alerts once after the temperature stays above \(settings.temperatureAlertThreshold) °C for 3 minutes.", bundle: .module)
                case .alerted:
                    Text("Can alert again after the temperature stays below \(settings.temperatureAlertThreshold - 2) °C for 5 minutes.", bundle: .module)
                }
                Text("The panel marks the temperature as High at or above the temperature threshold.", bundle: .module)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var healthSection: some View {
        Section {
            Toggle(isOn: $settings.healthAlertEnabled) {
                Text("Low Battery Health", bundle: .module)
            }
            Stepper(value: $settings.healthAlertThreshold, in: AppSettings.healthThresholdRange) {
                Text("Maximum capacity below \(settings.healthAlertThreshold)%", bundle: .module)
                    .monospacedDigit()
            }
            .disabled(!settings.healthAlertEnabled)
            LabeledContent {
                Text(verbatim: DisplayFormat.percent(alerts.latestMaximumCapacity))
                    .monospacedDigit()
            } label: {
                Text("Current Maximum Capacity", bundle: .module)
            }
            AlertStatusRow(status: alerts.healthStatus)
        } footer: {
            switch alerts.healthStatus {
            case .off:
                EmptyView()
            case .waiting:
                Text("Checked hourly against the maximum capacity reported by the system. Alerts once.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .alerted:
                Text("Already alerted at this threshold. Alerts again only after you change the threshold.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

private struct AlertStatusRow: View {
    let status: AlertStatus

    var body: some View {
        LabeledContent {
            switch status {
            case .off: Text("Off", bundle: .module)
            case .waiting: Text("Waiting", bundle: .module)
            case .alerted: Text("Alerted", bundle: .module)
            }
        } label: {
            Text("Status", bundle: .module)
        }
    }
}
