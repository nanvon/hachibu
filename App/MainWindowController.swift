import AppKit
import BatteryCore
import FeatureUI
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口。LSUIElement 应用默认不激活，打开主窗口时显式激活。
/// 窗口显示期间历史数据每分钟刷新，关闭后停止。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private var history: HistoryModel?

    convenience init(history: HistoryModel, settings: AppSettings, alerts: AlertMonitor, updates: UpdateController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hachibu"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        self.init(window: window)
        self.history = history
        window.contentView = NSHostingView(rootView: MainWindowRootView(
            history: history,
            settings: settings,
            alerts: alerts,
            onExportDiagnostics: { [weak self] in
                await self?.exportDiagnostics()
            },
            onCheckForUpdates: updates.isAvailable ? { @MainActor in updates.checkForUpdates() } : nil
        ))
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

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
