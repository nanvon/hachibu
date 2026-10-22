import AppKit
import os
import ServiceManagement
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Settings")

/// 设置页。设置项见 docs/v1技术设计.md 第 13 节。
struct SettingsPage: View {
    @Bindable var settings: AppSettings
    let onExportDiagnostics: @MainActor () async -> Void
    @State private var loginItem = LoginItem()
    @State private var isExporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings", bundle: .module)
                .font(.title2.weight(.semibold))
                .padding([.horizontal, .top], 24)

            Form {
                menuBarSection
                generalSection
                notificationsSection
                diagnosticsSection
            }
            .formStyle(.grouped)
        }
        .onAppear { loginItem.refresh() }
        // 用户可能在系统设置里批准或关闭登录项后切回来。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var menuBarSection: some View {
        Section {
            Picker(selection: $settings.menuBarContent) {
                ForEach(MenuBarContent.allCases, id: \.self) { content in
                    content.title.tag(content)
                }
            } label: {
                Text("Show in Menu Bar", bundle: .module)
            }
        } header: {
            Text("Menu Bar", bundle: .module)
        }
    }

    private var generalSection: some View {
        Section {
            Toggle(isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) })) {
                Text("Launch at Login", bundle: .module)
                if let note = loginItem.statusNote {
                    note
                }
            }
            if loginItem.status == .requiresApproval {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Open Login Items Settings…", bundle: .module)
                }
            }
            if let errorMessage = loginItem.errorMessage {
                Text(verbatim: errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("General", bundle: .module)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(isOn: $settings.temperatureAlertEnabled) {
                Text("High Battery Temperature", bundle: .module)
            }
            Stepper(value: $settings.temperatureAlertThreshold, in: AppSettings.temperatureThresholdRange) {
                Text("Temperature above \(settings.temperatureAlertThreshold) °C", bundle: .module)
                    .monospacedDigit()
            }
            Toggle(isOn: $settings.healthAlertEnabled) {
                Text("Low Battery Health", bundle: .module)
            }
            Stepper(value: $settings.healthAlertThreshold, in: AppSettings.healthThresholdRange) {
                Text("Maximum capacity below \(settings.healthAlertThreshold)%", bundle: .module)
                    .monospacedDigit()
            }
        } header: {
            Text("Notifications", bundle: .module)
        } footer: {
            Text("The panel marks the temperature as High at or above the temperature threshold.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                isExporting = true
                Task {
                    await onExportDiagnostics()
                    isExporting = false
                }
            } label: {
                Text("Export Diagnostic Data…", bundle: .module)
            }
            .disabled(isExporting)
        } header: {
            Text("Diagnostics", bundle: .module)
        } footer: {
            Text("Saves the current battery readings as a JSON file you can attach to an issue. Serial numbers and UUIDs are removed.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

extension MenuBarContent {
    var title: Text {
        switch self {
        case .batteryLevel: Text("Battery Level", bundle: .module)
        case .systemPower: Text("System Power", bundle: .module)
        case .temperature: Text("Temperature", bundle: .module)
        }
    }
}

/// 登录时启动，`SMAppService.mainApp`。显示系统返回的真实状态。
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    /// 最近一次注册或取消注册失败的原因。
    private(set) var errorMessage: String?

    /// 等待批准时也算已打开：已经注册，只差用户在系统设置里批准。
    var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    var statusNote: Text? {
        switch status {
        case .requiresApproval: Text("Requires approval in System Settings.", bundle: .module)
        case .notFound: Text("The system could not find this login item.", bundle: .module)
        default: nil
        }
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        if status != self.status {
            self.status = status
        }
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update login item: \(String(describing: error), privacy: .public)")
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
