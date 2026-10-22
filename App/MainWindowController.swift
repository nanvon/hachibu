import AppKit
import FeatureUI
import SwiftUI

/// 主窗口。LSUIElement 应用默认不激活，打开主窗口时显式激活。
/// 窗口显示期间历史数据每分钟刷新，关闭后停止。
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private var history: HistoryModel?

    convenience init(history: HistoryModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hachibu"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowRootView(history: history))
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        self.init(window: window)
        self.history = history
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
}
