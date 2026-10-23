import AppKit
import BatteryCore
import FeatureUI
import HistoryStore
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口。LSUIElement 应用默认不激活，打开主窗口时显式激活。
/// 窗口显示期间历史数据每分钟刷新，关闭后停止。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private var history: HistoryModel?
    private var store: HistoryStore?

    convenience init(history: HistoryModel, store: HistoryStore?, monitor: BatteryMonitor, settings: AppSettings, alerts: AlertMonitor, updates: UpdateController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Hachibu"
        // 工具栏和标题交给 SwiftUI（见下方 sceneBridgingOptions），侧栏由系统画成悬浮玻璃。见 docs/v1技术设计.md 19.3。
        window.toolbar = NSToolbar(identifier: "MainWindowToolbar")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        self.init(window: window)
        self.history = history
        self.store = store
        let importAction: (@MainActor @Sendable () async -> Bool)?
        if store != nil {
            importAction = { [weak self] in await self?.importHistory() ?? false }
        } else {
            importAction = nil
        }
        let hostingView = NSHostingView(rootView: MainWindowRootView(
            history: history,
            settings: settings,
            alerts: alerts,
            onExportDiagnostics: { [weak self] in
                await self?.exportDiagnostics()
            },
            onCheckForUpdates: updates.isAvailable ? { @MainActor in updates.checkForUpdates() } : nil,
            onImportHistory: importAction
        ).environment(monitor))
        hostingView.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = hostingView
        window.delegate = self
    }

    func showAndActivate() {
        history?.start()
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        history?.stop()
    }

    /// 选择保存位置后读取当前数据（已脱敏），写成 JSON。见 docs/v1技术设计.md 第 14 节。
    private func exportDiagnostics() async {
        guard let window else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.json]
        savePanel.nameFieldStringValue = "Hachibu-Diagnostics-\(Self.fileTimestamp(Date())).json"
        guard await savePanel.beginSheetModal(for: window) == .OK, let url = savePanel.url else { return }

        do {
            let report = await DiagnosticReport.collect()
            try report.jsonData().write(to: url, options: .atomic)
        } catch {
            await NSAlert(error: error).beginSheetModal(for: window)
        }
    }

    /// 文件选择、预览确认和结果窗口均由 AppKit 管理；解析在后台，确认后才写入。
    private func importHistory() async -> Bool {
        guard let window, let store else { return false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a complete history export.")
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return false }
        do {
            let archive = try await Task.detached(priority: .userInitiated) {
                try AlDenteArchive(data: Data(contentsOf: url))
            }.value
            guard window.isVisible else { return false }
            let confirmation = NSAlert()
            confirmation.messageText = String(localized: "Import History")
            confirmation.informativeText = String(localized: "\(archive.recordCount) records") + "\n\n"
                + String(localized: "History will be added to your existing charts. Existing measurements take priority where records overlap. All original values are preserved locally, including battery identifiers.")
            confirmation.addButton(withTitle: String(localized: "Import"))
            confirmation.addButton(withTitle: String(localized: "Cancel"))
            confirmation.accessoryView = Self.importPreview(archive.tables)
            guard await confirmation.beginSheetModal(for: window) == .alertFirstButtonReturn else { return false }

            let result = try await store.importAlDenteArchive(archive)
            await history?.reloadAfterImport()
            guard window.isVisible else { return true }
            let finished = NSAlert()
            finished.messageText = String(localized: "History Import Complete")
            finished.informativeText = String(localized: "Added \(result.addedRecords) records; \(result.existingRecords) records were already stored.")
            await finished.beginSheetModal(for: window)
            return true
        } catch {
            guard window.isVisible else { return false }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Could Not Import History")
            alert.informativeText = Self.importErrorDescription(error)
            await alert.beginSheetModal(for: window)
            return false
        }
    }

    private static func importPreview(_ tables: [AlDenteTableSummary]) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.string = tables.map { table in
            let count = String(localized: "\(table.recordCount) records")
            return "\(tableTitle(table.table)) · \(count)\n\(table.firstTimestamp ?? "—") → \(table.lastTimestamp ?? "—")"
        }.joined(separator: "\n\n")
        scroll.documentView = text
        return scroll
    }

    private static func tableTitle(_ table: AlDenteTable) -> String {
        switch table {
        case .batteryCycles: String(localized: "Cycle Count")
        case .batteryDesignCap: String(localized: "Design Capacity")
        case .batteryMaxCap: String(localized: "Full Charge Capacity")
        case .batteryPercentage: String(localized: "Battery Level")
        case .batterySerial: String(localized: "Battery Identifier")
        case .batteryTemp: String(localized: "Temperature")
        case .chargeLimit: String(localized: "Charge Limit History")
        case .chargingPower: String(localized: "Battery Power")
        case .lastCalibration: String(localized: "Calibration Records")
        case .macOSbatteryCondition: String(localized: "Battery Condition")
        case .macOSbatteryMaxCap: String(localized: "System Maximum Capacity")
        case .systemLoad: String(localized: "System Power")
        case .systemPowerIn: String(localized: "Input Power")
        }
    }

    private static func importErrorDescription(_ error: any Error) -> String {
        guard let error = error as? AlDenteArchiveError else { return error.localizedDescription }
        switch error {
        case .invalidJSON:
            return String(localized: "The file is not valid JSON.")
        case .unsupportedFormat:
            return String(localized: "Choose a complete history export in the supported format.")
        case .unsupportedVersion:
            return String(localized: "This export format version is not supported.")
        case .invalidSource:
            return String(localized: "The file is missing valid export metadata.")
        case .incompleteTables:
            return String(localized: "The export must contain all 13 source tables and their schema.")
        case .invalidTable(let name):
            return String(localized: "Invalid records, columns, or record count in table: \(name).")
        case .verificationFailed:
            return String(localized: "Record verification failed. The entire import was rolled back.")
        }
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
