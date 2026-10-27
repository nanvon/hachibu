import AppKit
import BatteryCore
import HistoryStore
import os
import ServiceManagement
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "Settings")

/// 设置页。两栏布局，设置项见 docs/v1技术设计.md 第 13 节，样式见 19.3。
struct SettingsPage: View {
    @Bindable var settings: AppSettings
    /// 数据库打不开时为 nil，不显示“历史数据”分组。
    var importer: HistoryImportModel?
    /// 由 App 层选择要导入的文件，取消时返回 nil。
    var onChooseImportFile: @MainActor () async -> URL? = { nil }
    let onExportDiagnostics: @MainActor () async -> Void
    /// 为 nil 时不显示“检查更新”。
    let onCheckForUpdates: (@MainActor () -> Void)?

    var body: some View {
        ScrollView {
            SettingsPageContent(
                settings: settings,
                importer: importer,
                onChooseImportFile: onChooseImportFile,
                onExportDiagnostics: onExportDiagnostics,
                onCheckForUpdates: onCheckForUpdates
            )
        }
    }
}

/// 与页面共用的内容；渲染测试直接渲染内容，避开 ImageRenderer 无法绘制的 AppKit 滚动容器。
struct SettingsPageContent: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Bindable var settings: AppSettings
    var importer: HistoryImportModel?
    var onChooseImportFile: @MainActor () async -> URL? = { nil }
    let onExportDiagnostics: @MainActor () async -> Void
    let onCheckForUpdates: (@MainActor () -> Void)?
    @State private var loginItem = LoginItem()
    @State private var isExporting = false
    @State private var couldNotOpenBatterySettings = false

    var body: some View {
        // 充电上限最常用，放在最前；导入、诊断和关于用得少，放在后面。
        SettingsColumns {
            chargingGroup
            SettingsGroupDivider()
            menuBarGroup
            SettingsGroupDivider()
            generalGroup
            if let importer {
                SettingsGroupDivider()
                HistoryDataGroup(importer: importer, onChooseFile: onChooseImportFile)
            }
            SettingsGroupDivider()
            diagnosticsGroup
            SettingsGroupDivider()
            aboutGroup
        }
        .onAppear { loginItem.refresh() }
        // 用户可能在系统设置里批准或关闭登录项后切回来。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    // MARK: 电池充电

    private var chargingGroup: some View {
        SettingsGroup(
            Text("Battery Charging", bundle: .module),
            description: chargeLimitControl != nil
                ? Text("Changes the same setting as System Settings → Battery.", bundle: .module)
                : Text("Change the charge limit in System Settings → Battery. Requires macOS 26.4 or later.", bundle: .module)
        ) {
            switch monitor.reading {
            case nil:
                SettingsRow(Text("System Charge Limit", bundle: .module)) {
                    ProgressView()
                        .controlSize(.small)
                }
            case .noBattery:
                SettingsRow(Text("No Battery Detected", bundle: .module)) {
                    EmptyView()
                }
            case .battery(let snapshot):
                if let control = chargeLimitControl {
                    ChargeLimitControlRows(control: control) { change in
                        Task { await monitor.setChargeLimit(change) }
                    }
                    if control.isEnabled {
                        SettingsRowDivider()
                        SettingsRow(
                            Text("When Above Limit", bundle: .module),
                            subtitle: settings.chargeAboveLimitAction == .holdCurrentCharge
                                ? Text("Hold Current Charge temporarily sets the system limit to the current level (up to 99%) so the charger powers your Mac. Your limit is restored when you unplug, switch back, or quit Hachibu.", bundle: .module)
                                : nil
                        ) {
                            SettingsMenu(
                                selection: $settings.chargeAboveLimitAction,
                                options: ChargeAboveLimitAction.allCases,
                                title: \.title,
                                label: Text("When Above Limit", bundle: .module)
                            )
                            .disabled(control.isBlocked)
                        }
                    }
                } else {
                    SettingsRow(Text("System Charge Limit", bundle: .module)) {
                        ChargeLimitValue(setting: snapshot.chargeLimit)
                    }
                }
                SettingsRowDivider()
                SettingsRow(Text("Current Status", bundle: .module)) {
                    StatusLabel(status: ChargeStatus(snapshot))
                }
            }
            SettingsRowDivider()
            SettingsPanelFooter {
                Button {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
                    couldNotOpenBatterySettings = url.map { NSWorkspace.shared.open($0) } != true
                } label: {
                    Text("Open Battery Settings…", bundle: .module)
                }
                .settingsButtonStyle()
            }
            if couldNotOpenBatterySettings {
                SettingsNote(text: Text("Could not open Battery settings. Open System Settings → Battery manually.", bundle: .module), isError: true)
            }
        }
    }

    private var chargeLimitControl: ChargeLimitControl? {
        ChargeLimitControl(monitor: monitor)
    }

    // MARK: 菜单栏

    private var menuBarGroup: some View {
        SettingsGroup(
            Text("Menu Bar", bundle: .module),
            description: Text("Icons turn yellow in Low Power Mode. The iOS style shows the percentage inside the battery.", bundle: .module)
        ) {
            SettingsRow(Text("Menu Bar Icon", bundle: .module)) {
                MenuBarIconChoice(selection: $settings.menuBarIconStyle)
            }
            SettingsRowDivider()
            SettingsRow(Text("Show in Menu Bar", bundle: .module)) {
                SettingsMenu(
                    selection: $settings.menuBarContent,
                    options: MenuBarContent.allCases,
                    title: \.title,
                    label: Text("Show in Menu Bar", bundle: .module)
                )
            }
        }
    }

    // MARK: 通用

    private var generalGroup: some View {
        SettingsGroup(
            Text("General", bundle: .module),
            description: Text("After you close this window, Hachibu stays in the menu bar and keeps recording.", bundle: .module)
        ) {
            SettingsRow(Text("Launch at Login", bundle: .module), subtitle: loginItem.statusNote) {
                SettingsSwitch(
                    isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }),
                    label: Text("Launch at Login", bundle: .module)
                )
            }
            if loginItem.status == .requiresApproval {
                SettingsRowDivider()
                SettingsPanelFooter {
                    Button {
                        SMAppService.openSystemSettingsLoginItems()
                    } label: {
                        Text("Open Login Items Settings…", bundle: .module)
                    }
                    .settingsButtonStyle()
                }
            }
            if let errorMessage = loginItem.errorMessage {
                SettingsNote(text: Text(verbatim: errorMessage), isError: true)
            }
        }
    }

    // MARK: 诊断、关于

    private var diagnosticsGroup: some View {
        SettingsGroup(
            Text("Diagnostics", bundle: .module),
            description: Text("Saves the current battery readings as a JSON file you can attach to an issue. Serial numbers and UUIDs are removed.", bundle: .module)
        ) {
            SettingsRow(Text("Diagnostic Data", bundle: .module)) {
                Button {
                    isExporting = true
                    Task {
                        await onExportDiagnostics()
                        isExporting = false
                    }
                } label: {
                    Text("Export…", bundle: .module)
                }
                .settingsButtonStyle()
                .disabled(isExporting)
            }
        }
    }

    private var aboutGroup: some View {
        SettingsGroup(Text("About", bundle: .module)) {
            Image("BrandLogo", bundle: .module)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 43, alignment: .leading)
                .accessibilityLabel(Text(verbatim: "Hachibu"))
        } panel: {
            SettingsRow(Text("Version", bundle: .module)) {
                HStack(spacing: 10) {
                    Text(verbatim: AboutInfo.version)
                        .textSelection(.enabled)
                    if let onCheckForUpdates {
                        Button {
                            onCheckForUpdates()
                        } label: {
                            Text("Check for Updates…", bundle: .module)
                        }
                        .settingsButtonStyle()
                    }
                }
            }
            SettingsRowDivider()
            SettingsRow(Text("Source Code", bundle: .module)) {
                SettingsLink(destination: AboutInfo.repositoryURL, text: AboutInfo.repositoryDisplayName)
            }
            if let license = AboutInfo.license {
                SettingsRowDivider()
                SettingsRow(Text("License", bundle: .module)) {
                    SettingsLink(destination: AboutInfo.licenseURL, text: license)
                }
            }
        }
    }
}

/// 菜单栏图标的两种样式，各画一个示意图标，选中的有品牌蓝描边。
private struct MenuBarIconChoice: View {
    @Binding var selection: MenuBarIconStyle

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                let isSelected = style == selection
                Button {
                    selection = style
                } label: {
                    HStack(spacing: 7) {
                        MenuBarIconSample(style: style)
                        style.title
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(isSelected ? 0 : 0.04))
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isSelected ? Color.brand : Color.primary.opacity(0.15), lineWidth: isSelected ? 1.5 : 0.5)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// 设置页里的菜单栏图标示意：macOS 样式为描边电池加填充，iOS 样式为实心电池内写电量。
/// 只用于选择，不与菜单栏的实际绘制（App 层的 BatteryIconDrawing）逐像素一致。
private struct MenuBarIconSample: View {
    let style: MenuBarIconStyle

    var body: some View {
        HStack(spacing: 1) {
            switch style {
            case .battery:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary, lineWidth: 1)
                    .frame(width: 22, height: 11)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.primary)
                            .frame(width: 13, height: 6)
                            .padding(.leading, 2.5)
                    }
            case .ios:
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Color.primary)
                    .frame(width: 22, height: 11)
                    .overlay {
                        Text(verbatim: "80")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.background)
                    }
            }
            Capsule()
                .fill(Color.primary.opacity(0.6))
                .frame(width: 1.5, height: 4)
        }
        .accessibilityHidden(true)
    }
}

/// 导入历史数据，列出和删除已导入的来源。见 docs/v1技术设计.md 20.6。
private struct HistoryDataGroup: View {
    let importer: HistoryImportModel
    let onChooseFile: @MainActor () async -> URL?
    @State private var pendingDeletion: ImportedSource?

    var body: some View {
        SettingsGroup(
            Text("History Data", bundle: .module),
            description: Text("Imports daily full charge capacity, cycle count and maximum capacity from a file in the Hachibu import format. Imported data stays on this Mac and is not included in diagnostic data.", bundle: .module)
        ) {
            ForEach(importer.sources) { source in
                SettingsRow(
                    Text(verbatim: Self.name(source)),
                    subtitle: Text("\(Self.dayRange(first: source.firstDay, last: source.lastDay)) · \(source.dayCount) days · Imported \(source.importedAt.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
                ) {
                    Button(role: .destructive) {
                        pendingDeletion = source
                    } label: {
                        Text("Delete…", bundle: .module)
                            .foregroundStyle(.red)
                    }
                    .settingsButtonStyle()
                    .disabled(importer.isWorking)
                }
                SettingsRowDivider()
            }
            SettingsPanelFooter {
                Button {
                    Task {
                        if let url = await onChooseFile() {
                            await importer.prepare(fileURL: url)
                        }
                    }
                } label: {
                    Text("Import History…", bundle: .module)
                }
                .settingsButtonStyle()
                .disabled(importer.isWorking)
            }
            if let failure = importer.failure {
                SettingsNote(text: Self.message(failure), isError: true)
            }
        }
        .task { await importer.loadSources() }
        .alert(
            Text("Import History?", bundle: .module),
            isPresented: Binding(get: { importer.pending != nil }, set: { if !$0 { importer.cancelImport() } }),
            presenting: importer.pending
        ) { preview in
            Button {
                Task { await importer.confirmImport(preview) }
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

/// 系统充电上限的开关和档位：开关一行，开启时下方为铺满宽度的档位（与面板相同的 `LimitSegments`）。
private struct ChargeLimitControlRows: View {
    let control: ChargeLimitControl
    let onChange: @MainActor (ChargeLimitChange) -> Void

    var body: some View {
        SettingsRow(Text("System Charge Limit", bundle: .module)) {
            SettingsSwitch(
                isOn: Binding(get: { control.isEnabled }, set: { onChange($0 ? .enable : .disable) }),
                label: Text("System Charge Limit", bundle: .module)
            )
            .disabled(!control.isInteractive)
        }
        if control.isEnabled {
            LimitSegments(options: control.options, selection: control.percent) { onChange(.limit($0)) }
                .disabled(!control.isInteractive)
                .padding(.bottom, 10)
        }
        if control.isBlocked || control.writeFailed {
            ChargeLimitNote(control: control)
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
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

extension ChargeAboveLimitAction {
    var title: Text {
        switch self {
        case .dischargeToLimit: Text("Discharge to Limit", bundle: .module)
        case .holdCurrentCharge: Text("Hold Current Charge", bundle: .module)
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
/// 模拟插电未充电的电池和 PowerUI：写入后读回新的开关和上限。`isSupported` 为 false 时表示系统不支持充电上限。
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
