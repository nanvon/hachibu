import AppKit
import BatteryCore
import FeatureUI
import Observation

/// 菜单栏图标：显示设置里选择的读数，点击切换面板的显示。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panelController: PanelController
    private let monitor: BatteryMonitor
    private let settings: AppSettings
    private var lastIcon: MenuBarIcon?
    private var appearanceObservation: NSKeyValueObservation?

    init(panelController: PanelController, monitor: BatteryMonitor, settings: AppSettings) {
        self.panelController = panelController
        self.monitor = monitor
        self.settings = settings
        super.init()

        guard let button = statusItem.button else { return }
        // 等宽数字，数值变化时宽度不跳动。
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.target = self
        button.action = #selector(togglePanel(_:))
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updatePresentation() }
        }
        updatePresentation()
    }

    /// 读数或设置变化时更新；只有图标所需状态变化才重新绘制。
    private func updatePresentation() {
        guard let button = statusItem.button else { return }
        let presentation = withObservationTracking {
            (
                title: MenuBarTitle.string(for: monitor.reading, content: settings.menuBarContent),
                content: settings.menuBarContent,
                icon: MenuBarIcon(style: settings.menuBarIconStyle, reading: monitor.reading, appearance: button.effectiveAppearance)
            )
        } onChange: { [weak self] in
            Task { @MainActor in self?.updatePresentation() }
        }
        let title = presentation.icon.style == .ios && presentation.content == .batteryLevel && presentation.icon.percent != nil
            ? "" : presentation.title
        if button.title != title {
            button.title = title
        }
        // iOS 样式可以只显示图片，仍通过原始读数提供无障碍文字。
        let batteryTitle = MenuBarTitle.string(for: monitor.reading, content: .batteryLevel)
        let accessibilityTitle = presentation.icon.style == .ios && presentation.content != .batteryLevel
            ? "\(batteryTitle), \(presentation.title)" : presentation.title
        button.setAccessibilityLabel("Hachibu, \(accessibilityTitle)")
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if lastIcon != presentation.icon {
            button.image = presentation.icon.image()
            lastIcon = presentation.icon
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panelController.toggle(relativeTo: sender)
    }
}
