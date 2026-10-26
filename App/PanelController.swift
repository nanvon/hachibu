import AppKit
import FeatureUI
import SwiftUI

/// 菜单栏弹出面板：负责定位、显示和关闭；内容由 FeatureUI 提供。
/// 关闭时机：再次点击菜单栏图标、点击面板以外的位置、按 Esc、面板失去 key 状态。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private static let cornerRadius: CGFloat = 28
    private static let gapBelowMenuBar: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    /// 与 FeatureUI 中内容展开、收起的动画时长接近。
    private static let resizeDuration: TimeInterval = 0.3

    private let panel: StatusPanel
    private let onVisibilityChange: @MainActor (Bool) -> Void
    private var content: NSView?
    private weak var anchorButton: NSStatusBarButton?
    private var eventMonitors: [Any] = []

    /// `onVisibilityChange` 在面板显示、关闭时调用，用于切换采样频率。
    init(
        monitor: BatteryMonitor,
        settings: AppSettings,
        onOpenMainWindow: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onVisibilityChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.onVisibilityChange = onVisibilityChange
        panel = StatusPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        let content = PanelHostingView(rootView: PanelRootView(
            monitor: monitor,
            settings: settings,
            onOpenMainWindow: { [weak self] in
                self?.close()
                onOpenMainWindow()
            },
            onOpenSettings: { [weak self] in
                self?.close()
                onOpenSettings()
            },
            onQuit: { NSApp.terminate(nil) }
        ))
        // 只用内容的理想尺寸，不加最小、最大尺寸约束；面板大小由 fitToContent() 设置。
        content.sizingOptions = [.intrinsicContentSize]
        content.onIntrinsicContentSizeChange = { [weak self] in
            guard let self else { return }
            // 在当前布局过程结束后再改窗口大小。
            Task { self.fitToContent(animated: true) }
        }
        self.content = content

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = Self.makeBackground(for: content)
        panel.setContentSize(content.fittingSize)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeEventMonitors()
        onVisibilityChange(false)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: - Private

    private func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchorButton = button

        // 每次打开都按按钮当前所在的屏幕重新计算位置。
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visibleFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame
        fitToContent()
        let size = panel.frame.size
        let x = min(
            max(buttonFrame.midX - size.width / 2, visibleFrame.minX + Self.screenMargin),
            visibleFrame.maxX - size.width - Self.screenMargin
        )
        let y = buttonFrame.minY - size.height - Self.gapBelowMenuBar
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.makeKeyAndOrderFront(nil)
        installEventMonitors()
        onVisibilityChange(true)
    }

    /// 按内容的理想尺寸调整面板大小，保持顶边位置不变（面板挂在菜单栏下方）。
    /// 面板显示时内容增减（例如插拔电、切换充电上限）用动画跟随，见 docs/v1技术设计.md 第 19.7 节。
    private func fitToContent(animated: Bool = false) {
        guard let size = content?.fittingSize, size != panel.frame.size else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size

        guard animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: panel.isVisible)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func installEventMonitors() {
        removeEventMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        // 其他应用里的点击。
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.close()
        }) {
            eventMonitors.append(monitor)
        }

        // 本应用里、面板和菜单栏图标以外的点击（例如主窗口）。
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let self, event.window !== self.panel, event.window !== self.anchorButton?.window {
                self.close()
            }
            return event
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    private static func makeBackground(for content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
        }

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }
}

/// 内容的理想尺寸变化时（例如插拔电时显示或隐藏充电器卡片）通知面板调整大小。
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onIntrinsicContentSizeChange: (@MainActor () -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicContentSizeChange?()
    }
}

/// 无边框面板默认不能成为 key window，需要键盘事件（Esc）时要覆盖。
final class StatusPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
