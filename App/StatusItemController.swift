import AppKit
import BatteryCore
import FeatureUI
import Observation

/// 菜单栏图标：显示设置里选择的读数，点击切换面板的显示。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panelController: PanelController
    private let monitor: BatteryMonitor
    private let settings: AppSettings
    private var lastIcon: MenuBarIcon?
    private var lastAccessibilityLabel: String?
    private var isPresentationUpdateScheduled = false
    private var appearanceObservation: NSKeyValueObservation?

    init(panelController: PanelController, monitor: BatteryMonitor, settings: AppSettings, statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.panelController = panelController
        self.monitor = monitor
        self.settings = settings
        super.init()

        guard let button = statusItem.button else { return }
        button.isEnabled = true
        // 等宽数字，数值变化时宽度不跳动。
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        button.target = self
        button.action = #selector(togglePanel(_:))
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.schedulePresentationUpdate() }
        }
        observePresentationChanges()
        updatePresentation()
    }

    /// 只在读数或设置变化后续订，外观刷新不重复注册监听。
    private func observePresentationChanges() {
        withObservationTracking {
            _ = monitor.reading
            _ = settings.menuBarContent
            _ = settings.menuBarIconStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observePresentationChanges()
                self.schedulePresentationUpdate()
            }
        }
    }

    /// 合并同一轮读数、设置与外观变化产生的刷新请求。
    private func schedulePresentationUpdate() {
        guard !isPresentationUpdateScheduled else { return }
        isPresentationUpdateScheduled = true
        Task { [weak self] in
            guard let self else { return }
            self.isPresentationUpdateScheduled = false
            self.updatePresentation()
        }
    }

    /// 相同值不写回按钮，避免菜单栏重绘产生外观通知后再次触发布局。
    private func updatePresentation() {
        guard let button = statusItem.button else { return }
        let presentation = (
            title: MenuBarTitle.string(for: monitor.reading, content: settings.menuBarContent),
            content: settings.menuBarContent,
            icon: MenuBarIcon(style: settings.menuBarIconStyle, reading: monitor.reading, appearance: button.effectiveAppearance)
        )
        let title = presentation.icon.style == .ios && presentation.content == .batteryLevel && presentation.icon.percent != nil
            ? "" : presentation.title
        if button.title != title {
            button.title = title
        }
        // iOS 样式可以只显示图片，仍通过原始读数提供无障碍文字。
        let batteryTitle = MenuBarTitle.string(for: monitor.reading, content: .batteryLevel)
        let accessibilityTitle = presentation.icon.style == .ios && presentation.content != .batteryLevel
            ? "\(batteryTitle), \(presentation.title)" : presentation.title
        let accessibilityLabel = "Hachibu, \(accessibilityTitle)"
        if lastAccessibilityLabel != accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
            lastAccessibilityLabel = accessibilityLabel
        }
        let imagePosition: NSControl.ImagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if button.imagePosition != imagePosition {
            button.imagePosition = imagePosition
        }
        if lastIcon != presentation.icon {
            button.image = presentation.icon.image()
            lastIcon = presentation.icon
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panelController.toggle(relativeTo: sender)
    }
}
