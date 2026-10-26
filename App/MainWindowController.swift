import AppKit
import BatteryCore
import FeatureUI
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口。打开时显示 Dock 图标并激活，关闭后恢复菜单栏常驻模式。
/// 窗口显示期间历史数据每分钟刷新，关闭后停止。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private var history: HistoryModel?

    convenience init(history: HistoryModel, monitor: BatteryMonitor, settings: AppSettings, alerts: AlertMonitor, updates: UpdateController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 840),
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
        let hostingView = NSHostingView(rootView: MainWindowRootView(
            history: history,
            settings: settings,
            alerts: alerts,
            onExportDiagnostics: { [weak self] in
                await self?.exportDiagnostics()
            },
            onChooseImportFile: { [weak self] in
                await self?.chooseImportFile()
            },
            onCheckForUpdates: updates.isAvailable ? { @MainActor in updates.checkForUpdates() } : nil
        ).environment(monitor))
        hostingView.sceneBridgingOptions = [.toolbars, .title]
        window.contentView = hostingView
        window.delegate = self
    }

    func showAndActivate() {
        NSApp.setActivationPolicy(.regular)
        history?.start()
        showWindow(nil)
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        // 面板是 .nonactivatingPanel，点击后本应用仍不是前台应用，NSApp.activate() 会被系统拒绝，
        // 窗口留在其他应用后面。见 https://developer.apple.com/forums/thread/836619
        (NSApp as any LegacyActivation).activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        history?.stop()
        NSApp.setActivationPolicy(.accessory)
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

    /// 选择要导入的历史数据文件（JSON）。取消时返回 nil。见 docs/v1技术设计.md 20.6。
    private func chooseImportFile() async -> URL? {
        guard let window else { return nil }
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.json]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        guard await openPanel.beginSheetModal(for: window) == .OK else { return nil }
        return openPanel.url
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// `activate(ignoringOtherApps:)` 自 macOS 14 弃用，但菜单栏应用从非激活面板打开窗口时只有它能把窗口带到前面。
/// 经协议调用，避免弃用警告。
@MainActor
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivation {}
