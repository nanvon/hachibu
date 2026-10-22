import AppKit
import FeatureUI
import SwiftUI

/// 主窗口。LSUIElement 应用默认不激活，打开主窗口时显式激活。
@MainActor
final class MainWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hachibu"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainWindowRootView())
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }
        self.init(window: window)
    }

    func showAndActivate() {
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
