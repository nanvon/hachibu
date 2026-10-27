import AppKit
import FeatureUI
import SwiftUI

/// 菜单栏弹出面板：负责定位、显示和关闭；内容由 FeatureUI 提供。
/// 关闭时机：再次点击菜单栏图标、点击面板以外的位置、按 Esc、切换到其他应用。
@MainActor
final class PanelController: NSObject {
    private static let cornerRadius: CGFloat = 28
    private static let gapBelowMenuBar: CGFloat = 6
    private static let screenMargin: CGFloat = 8
    /// 与 FeatureUI 中内容展开、收起的动画（`PanelMotion.duration`）相同。
    private static let resizeDuration: TimeInterval = 0.3

    private let panel: StatusPanel
    private let onVisibilityChange: @MainActor (Bool) -> Void
    private var content: NSView?
    private weak var anchorButton: NSStatusBarButton?
    private var eventMonitors: [Any] = []
    private var applicationActivationObserver: NSObjectProtocol?

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
        panel.invalidateShadow()
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
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            // 与面板内容的 PanelMotion 同样的强 ease-out 曲线和时长，窗口边缘和内容同步。
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.panel.invalidateShadow()
            }
        }
    }

    private func installEventMonitors() {
        removeEventMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        // 非激活面板失去 key 可能早于菜单栏按钮 action，不能据此关闭。
        // 改为监听应用切换，让 Command-Tab 等没有鼠标点击的操作也能关闭面板。
        applicationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let processIdentifier = application.processIdentifier
            MainActor.assumeIsolated {
                guard processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.close()
            }
        }

        // 其他应用里的点击。
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, !self.isAnchorButtonClick(event) else { return }
            self.close()
        }) {
            eventMonitors.append(monitor)
        }

        // 本应用里、面板和菜单栏图标以外的点击（例如主窗口）。
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if let self, event.window !== self.panel, !self.isAnchorButtonClick(event) {
                self.close()
            }
            return event
        }) {
            eventMonitors.append(monitor)
        }
    }

    private func isAnchorButtonClick(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown || event.type == .leftMouseUp,
              let button = anchorButton, let window = button.window else {
            return false
        }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonFrame.contains(NSEvent.mouseLocation)
    }

    private func removeEventMonitors() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        if let applicationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(applicationActivationObserver)
            self.applicationActivationObserver = nil
        }
    }

    private static func makeBackground(for content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // 玻璃圆角只定义材质轮廓，同时裁剪承载内容的图层，避免圆角外露出矩形边。
            glass.wantsLayer = true
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
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
