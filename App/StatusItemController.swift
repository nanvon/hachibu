import AppKit
import FeatureUI
import Observation

/// 菜单栏图标：显示设置里选择的读数，点击切换面板的显示。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelController: PanelController
    private let monitor: BatteryMonitor
    private let settings: AppSettings

    init(panelController: PanelController, monitor: BatteryMonitor, settings: AppSettings) {
        self.panelController = panelController
        self.monitor = monitor
        self.settings = settings
        super.init()

        guard let button = statusItem.button else { return }
        // 固定品牌符号；实时电量、功率或温度仍由旁边的文字表达。
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        image?.size = NSSize(width: 22, height: 18)
        button.image = image
        button.imagePosition = .imageLeading
        // 等宽数字，数值变化时宽度不跳动。
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.target = self
        button.action = #selector(togglePanel(_:))
        updateTitle()
    }

    /// 读数或设置变化时更新文字；字符串没变就不更新。
    private func updateTitle() {
        let title = withObservationTracking {
            MenuBarTitle.string(for: monitor.reading, content: settings.menuBarContent)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateTitle() }
        }
        if let button = statusItem.button, button.title != title {
            button.title = title
            button.setAccessibilityLabel("Hachibu, \(title)")
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panelController.toggle(relativeTo: sender)
    }
}
