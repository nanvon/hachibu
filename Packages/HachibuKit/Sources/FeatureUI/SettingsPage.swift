import AppKit
import BatteryCore
import os
import ServiceManagement
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Settings")

/// 设置页。设置项见 docs/v1技术设计.md 第 13 节。
struct SettingsPage: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Bindable var settings: AppSettings
    let onExportDiagnostics: @MainActor () async -> Void
    /// 为 nil 时不显示“检查更新”。
    let onCheckForUpdates: (@MainActor () -> Void)?
    let onImportHistory: (@MainActor () async -> Void)?
    @State private var loginItem = LoginItem()
    @State private var isExporting = false
    @State private var couldNotOpenBatterySettings = false
    @State private var isImporting = false

    var body: some View {
        Form {
            menuBarSection
            generalSection
            chargingSection
            historyImportSection
            diagnosticsSection
            aboutSection
        }
        .formStyle(.grouped)
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

    private var chargingSection: some View {
        Section {
            switch monitor.reading {
            case nil:
                ProgressView()
                    .controlSize(.small)
            case .noBattery:
                Text("No Battery Detected", bundle: .module)
            case .battery(let snapshot):
                LabeledContent {
                    ChargeLimitValue(percent: snapshot.chargeLimitPercent)
                        .monospacedDigit()
                } label: {
                    Text("System Charge Limit", bundle: .module)
                }
                LabeledContent {
                    StatusLabel(status: ChargeStatus(snapshot))
                } label: {
                    Text("Current Status", bundle: .module)
                }
            }
            Button {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
                couldNotOpenBatterySettings = url.map { NSWorkspace.shared.open($0) } != true
            } label: {
                Text("Open Battery Settings…", bundle: .module)
            }
            if couldNotOpenBatterySettings {
                Text("Could not open Battery settings. Open System Settings → Battery manually.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Charging", bundle: .module)
        } footer: {
            Text("Manage charging options in System Settings → Battery. Hachibu only reads the charge limit; the value does not confirm that limiting is enabled or taking effect. Unknown does not mean off.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var historyImportSection: some View {
        Section {
            Button {
                guard let onImportHistory else { return }
                isImporting = true
                Task {
                    defer { isImporting = false }
                    await onImportHistory()
                }
            } label: {
                Text("Import AlDente History…", bundle: .module)
            }
            .disabled(isImporting || onImportHistory == nil)
            if isImporting {
                ProgressView()
                    .controlSize(.small)
            }
        } header: {
            Text("Historical Data", bundle: .module)
        } footer: {
            Text("Preserves all 13 source tables in a separate archive. Existing recordings and history charts are unchanged.", bundle: .module)
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

    private var aboutSection: some View {
        Section {
            Image("BrandLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 53)
                .accessibilityLabel(Text(verbatim: "Hachibu"))
                .padding(.vertical, 8)
            LabeledContent {
                Text(verbatim: AboutInfo.version)
                    .textSelection(.enabled)
            } label: {
                Text("Version", bundle: .module)
            }
            LabeledContent {
                Link(destination: AboutInfo.repositoryURL) {
                    Text(verbatim: AboutInfo.repositoryDisplayName)
                }
            } label: {
                Text("Source Code", bundle: .module)
            }
            if let license = AboutInfo.license {
                LabeledContent {
                    Link(destination: AboutInfo.licenseURL) {
                        Text(verbatim: license)
                    }
                } label: {
                    Text("License", bundle: .module)
                }
            }
            if let onCheckForUpdates {
                Button {
                    onCheckForUpdates()
                } label: {
                    Text("Check for Updates…", bundle: .module)
                }
            }
        } header: {
            Text("About", bundle: .module)
        }
    }
}

/// 设置页“关于”区显示的信息。
private enum AboutInfo {
    /// 仓库地址，与 Config/Base.xcconfig 的 SPARKLE_FEED_URL 指向同一个仓库。
    static let repositoryURL = URL(string: "https://github.com/nanvon/hachibu")!
    static let repositoryDisplayName = "github.com/nanvon/hachibu"
    static let licenseURL = repositoryURL.appending(path: "blob/main/LICENSE")
    /// 许可证的 SPDX 标识，见仓库根目录 LICENSE。为 nil 时不显示。
    static let license: String? = "GPL-3.0-only"

    /// 例如 “0.1.0 (1)”。读不到时显示“—”。
    static var version: String {
        let info = Bundle.main.infoDictionary
        guard let shortVersion = info?["CFBundleShortVersionString"] as? String else {
            return DisplayFormat.missing
        }
        guard let build = info?["CFBundleVersion"] as? String else {
            return shortVersion
        }
        return "\(shortVersion) (\(build))"
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
