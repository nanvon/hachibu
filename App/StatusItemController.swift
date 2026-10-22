import AppKit

/// 菜单栏图标。点击切换面板的显示。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelController: PanelController

    init(panelController: PanelController) {
        self.panelController = panelController
        super.init()

        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: "Hachibu") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "Hachibu"
        }
        button.target = self
        button.action = #selector(togglePanel(_:))
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panelController.toggle(relativeTo: sender)
    }
}
