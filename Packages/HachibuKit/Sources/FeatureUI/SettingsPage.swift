import AppKit
import BatteryCore
import HistoryStore
import os
import ServiceManagement
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Settings")

/// 设置页。设置项见 docs/v1技术设计.md 第 13 节。
struct SettingsPage: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Bindable var settings: AppSettings
    /// 数据库打不开时为 nil，不显示“历史数据”分区。
    var importer: HistoryImportModel?
    /// 由 App 层选择要导入的文件，取消时返回 nil。
    var onChooseImportFile: @MainActor () async -> URL? = { nil }
    let onExportDiagnostics: @MainActor () async -> Void
    /// 为 nil 时不显示“检查更新”。
    let onCheckForUpdates: (@MainActor () -> Void)?
    @State private var loginItem = LoginItem()
    @State private var isExporting = false
    @State private var couldNotOpenBatterySettings = false

    var body: some View {
        Form {
            menuBarSection
            generalSection
            chargingSection
            if let importer {
                HistoryDataSection(importer: importer, onChooseFile: onChooseImportFile)
            }
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
            Picker(selection: $settings.menuBarIconStyle) {
                ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                    style.title.tag(style)
                }
            } label: {
                Text("Menu Bar Icon", bundle: .module)
            }
            Picker(selection: $settings.menuBarContent) {
                ForEach(MenuBarContent.allCases, id: \.self) { content in
                    content.title.tag(content)
                }
            } label: {
                Text("Show in Menu Bar", bundle: .module)
            }
        } header: {
            Text("Menu Bar", bundle: .module)
        } footer: {
            Text("Icons turn yellow in Low Power Mode. The iOS style shows the percentage inside the battery.", bundle: .module)
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
                if let control = chargeLimitControl {
                    ChargeLimitControlRows(control: control) { change in
                        Task { await monitor.setChargeLimit(change) }
                    }
                } else {
                    LabeledContent {
                        ChargeLimitValue(setting: snapshot.chargeLimit)
                            .monospacedDigit()
                    } label: {
                        Text("System Charge Limit", bundle: .module)
                    }
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
            Text("Battery Charging", bundle: .module)
        } footer: {
            Group {
                if chargeLimitControl != nil {
                    Text("Changes the same setting as System Settings → Battery.", bundle: .module)
                } else {
                    Text("Change the charge limit in System Settings → Battery. Requires macOS 26.4 or later.", bundle: .module)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var chargeLimitControl: ChargeLimitControl? {
        ChargeLimitControl(monitor: monitor)
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

/// 导入历史数据，列出和删除已导入的来源。见 docs/v1技术设计.md 20.6。
private struct HistoryDataSection: View {
    let importer: HistoryImportModel
    let onChooseFile: @MainActor () async -> URL?
    @State private var pendingDeletion: ImportedSource?

    var body: some View {
        Section {
            ForEach(importer.sources) { source in
                LabeledContent {
                    Button(role: .destructive) {
                        pendingDeletion = source
                    } label: {
                        Text("Delete…", bundle: .module)
                    }
                    .disabled(importer.isWorking)
                } label: {
                    Text(verbatim: Self.name(source))
                    Text("\(Self.dayRange(first: source.firstDay, last: source.lastDay)) · \(source.dayCount) days · Imported \(source.importedAt.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
                }
            }
            Button {
                Task {
                    if let url = await onChooseFile() {
                        await importer.prepare(fileURL: url)
                    }
                }
            } label: {
                Text("Import History…", bundle: .module)
            }
            .disabled(importer.isWorking)
            if let failure = importer.failure {
                Self.message(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("History Data", bundle: .module)
        } footer: {
            Text("Imports daily full charge capacity, cycle count and maximum capacity from a file in the Hachibu import format. Imported data stays on this Mac and is not included in diagnostic data.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task { await importer.loadSources() }
        .alert(
            Text("Import History?", bundle: .module),
            isPresented: Binding(get: { importer.pending != nil }, set: { if !$0 { importer.cancelImport() } }),
            presenting: importer.pending
        ) { _ in
            Button {
                Task { await importer.confirmImport() }
            } label: {
                Text("Import", bundle: .module)
            }
            Button(role: .cancel) {
                importer.cancelImport()
            } label: {
                Text("Cancel", bundle: .module)
            }
        } message: { preview in
            Text(verbatim: Self.summary(preview))
        }
        .alert(
            Text("Delete Imported Data?", bundle: .module),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { source in
            Button(role: .destructive) {
                Task { await importer.delete(source) }
            } label: {
                Text("Delete", bundle: .module)
            }
            Button(role: .cancel) {} label: {
                Text("Cancel", bundle: .module)
            }
        } message: { source in
            Text("The \(source.dayCount) days imported from \(Self.name(source)) will be removed from the history charts.", bundle: .module)
        }
    }

    /// 如 “AlDente 1.39.3”。
    private static func name(_ source: ImportedSource) -> String {
        [source.app, source.appVersion].compactMap { $0 }.joined(separator: " ")
    }

    private static func dayRange(first: String?, last: String?) -> String {
        let dates = [first, last].compactMap { $0.flatMap { HistoryChartBuilder.startOfDay($0) } }
            .map { $0.formatted(date: .abbreviated, time: .omitted) }
        return dates.count == 2 ? "\(dates[0]) – \(dates[1])" : DisplayFormat.missing
    }

    /// 确认对话框的说明，每项一行。
    private static func summary(_ preview: HistoryImportPreview) -> String {
        let file = preview.file
        let name = [file.sourceApp, file.sourceVersion].compactMap { $0 }.joined(separator: " ")
        var lines = [
            String(localized: "\(name): \(file.dayCount) days, \(dayRange(first: file.firstDay, last: file.lastDay)).", bundle: .module),
        ]
        if preview.overlappingNativeDays > 0 {
            lines.append(String(localized: "\(preview.overlappingNativeDays) days were also recorded on this Mac. Those days keep this Mac's data and only fill in missing values.", bundle: .module))
        }
        if file.excludedCount > 0 || file.skippedCount > 0 {
            lines.append(String(localized: "Invalid records excluded: \(file.excludedCount). Unrecognized records skipped: \(file.skippedCount).", bundle: .module))
        }
        if !file.hasBatterySerial {
            lines.append(String(localized: "The file has no battery serial number, so the capacity ratio can't be calculated for imported days unless they include the design capacity.", bundle: .module))
        } else if preview.isDifferentBattery {
            lines.append(String(localized: "The data is from a different battery than the one in this Mac.", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }

    private static func message(_ failure: HistoryImportModel.Failure) -> Text {
        switch failure {
        case .invalidFile(.fileTooLarge): Text("The file is larger than 50 MB.", bundle: .module)
        case .invalidFile(.notJSON), .invalidFile(.unsupportedFormat):
            Text("The file is not in the Hachibu import format.", bundle: .module)
        case .invalidFile(.unsupportedVersion): Text("This version of the import format is not supported.", bundle: .module)
        case .invalidFile(.missingSourceApp): Text("The file does not name the app the data came from.", bundle: .module)
        case .invalidFile(.noValidRecords): Text("The file contains no valid daily data.", bundle: .module)
        case .invalidFile(.alreadyImported): Text("This file has already been imported.", bundle: .module)
        case .unreadable: Text("Could not read the file.", bundle: .module)
        case .writeFailed: Text("Could not save the imported data.", bundle: .module)
        }
    }
}

/// 系统充电上限的开关和档位。开启时才显示档位。
private struct ChargeLimitControlRows: View {
    let control: ChargeLimitControl
    let onChange: @MainActor (ChargeLimitChange) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { control.isEnabled }, set: { onChange($0 ? .enable : .disable) })) {
            Text("System Charge Limit", bundle: .module)
        }
        .disabled(!control.isInteractive)
        if control.isEnabled {
            Picker(selection: Binding(get: { control.percent ?? 0 }, set: { onChange(.limit($0)) })) {
                ForEach(control.options, id: \.self) { percent in
                    Text(verbatim: DisplayFormat.percent(percent)).tag(percent)
                }
            } label: {
                Text("Limit", bundle: .module)
            }
            .disabled(!control.isInteractive)
        }
        if control.isBlocked || control.writeFailed {
            ChargeLimitNote(control: control)
                .font(.callout)
        }
    }
}

/// 系统充电上限的读数：百分比、关闭、不支持；未知时显示“—”。
private struct ChargeLimitValue: View {
    let setting: ChargeLimitSetting?

    var body: some View {
        switch setting {
        case .on(let percent): Text(verbatim: DisplayFormat.percent(percent))
        case .off: Text("Off", bundle: .module)
        case .unsupported: Text("Not Supported", bundle: .module)
        case nil: Text(verbatim: DisplayFormat.missing)
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

extension MenuBarIconStyle {
    var title: Text {
        switch self {
        case .battery: Text("macOS", bundle: .module)
        case .ios: Text("iOS", bundle: .module)
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

// MARK: - 预览

#if DEBUG
/// 模拟接电未充电的电池和 PowerUI：写入后读回新的开关和上限。`isSupported` 为 false 时表示系统不支持充电上限。
private final class PreviewBatterySystem: BatteryDataSource, ChargeLimitWriter, @unchecked Sendable {
    private let lock = NSLock()
    private let isSupported: Bool
    private var isEnabled = true
    private var limit = 80

    init(isSupported: Bool) {
        self.isSupported = isSupported
    }

    func read() -> RawBatteryReadings {
        lock.withLock {
            RawBatteryReadings(
                powerSources: [[
                    "Type": .string("InternalBattery"),
                    "Current Capacity": .int(80), "Max Capacity": .int(100),
                    "Power Source State": .string("AC Power"),
                    "Is Charging": .bool(false),
                ]],
                smartBattery: nil,
                smartBatteryPack: nil,
                adapterDetails: nil,
                chargeLimitArchive: nil,
                powerUIChargeLimit: isSupported
                    ? PowerUIChargeLimit(isSupported: true, isEnabled: isEnabled, limit: isEnabled ? limit : 100, availableLimits: [80, 85, 90, 95, 100])
                    : PowerUIChargeLimit(isSupported: false),
                lowPowerModeEnabled: false
            )
        }
    }

    func write(_ change: ChargeLimitChange) throws {
        lock.withLock {
            switch change {
            case .enable: isEnabled = true
            case .disable: isEnabled = false
            case .limit(let percent): limit = percent
            }
        }
    }
}

private struct PreviewProfiler: SystemProfilerSource {
    func readPowerData() async throws -> RawValue { .dictionary([:]) }
}

/// 设置存在独立的 UserDefaults；电池读数来自 PreviewBatterySystem，不读取硬件。
private struct SettingsPreview: View {
    @State private var settings: AppSettings
    @State private var monitor: BatteryMonitor
    private let showsCheckForUpdates: Bool

    init(canWriteChargeLimit: Bool, isSupported: Bool = true, showsCheckForUpdates: Bool = true) {
        let defaults = UserDefaults(suiteName: "HachibuPreview.Settings")!
        defaults.removePersistentDomain(forName: "HachibuPreview.Settings")
        let system = PreviewBatterySystem(isSupported: isSupported)
        let sampler = BatterySampler(
            dataSource: system,
            systemProfiler: PreviewProfiler(),
            chargeLimitWriter: canWriteChargeLimit ? system : nil,
            store: nil
        )
        _settings = State(initialValue: AppSettings(defaults: defaults))
        _monitor = State(initialValue: BatteryMonitor(sampler: sampler, powerSourceReader: { nil }))
        self.showsCheckForUpdates = showsCheckForUpdates
    }

    var body: some View {
        SettingsPage(settings: settings, onExportDiagnostics: {}, onCheckForUpdates: showsCheckForUpdates ? { @MainActor in } : nil)
            .environment(monitor)
            .task { await monitor.read() }
            .frame(width: 720, height: 900)
    }
}

#Preview("Charge Limit Control") {
    SettingsPreview(canWriteChargeLimit: true)
}

#Preview("Read Only, Updates Disabled") {
    SettingsPreview(canWriteChargeLimit: false, showsCheckForUpdates: false)
}

#Preview("Charge Limit Not Supported") {
    SettingsPreview(canWriteChargeLimit: false, isSupported: false)
}
#endif
