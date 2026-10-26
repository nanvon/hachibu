import AppKit
import FeatureUI
import HistoryStore
import Observation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var historyStore: HistoryStore?
    private var batteryMonitor: BatteryMonitor?
    private let settings = AppSettings()
    private lazy var alertMonitor = AlertMonitor(settings: settings, notifier: SystemAlertNotifier())
    private let updateController = UpdateController()
    private var statusItemController: StatusItemController?
    private var mainWindowController: MainWindowController?
    private var pendingSettings: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        // 先显示入口；数据库打开、迁移和 PowerUI 能力检查不占用主线程。
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.isEnabled = false
        Task {
            let (store, sampler) = await Task.detached(priority: .userInitiated) {
                let store = Self.openHistoryStore()
                return (store, BatterySampler(store: store))
            }.value
            configure(store: store, sampler: sampler, statusItem: statusItem)
        }
    }

    private func configure(store: HistoryStore?, sampler: BatterySampler, statusItem: NSStatusItem) {
        historyStore = store
        let batteryMonitor = BatteryMonitor(sampler: sampler)
        self.batteryMonitor = batteryMonitor
        batteryMonitor.onRead = { [alertMonitor] reading, date in
            await alertMonitor.handleReading(reading, at: date)
        }
        batteryMonitor.onHealthRefresh = { [alertMonitor] health in
            await alertMonitor.handleHealth(health)
        }
        alertMonitor.start()
        syncChargeAboveLimitAction()
        batteryMonitor.start()

        let panelController = PanelController(
            monitor: batteryMonitor,
            settings: settings,
            onOpenMainWindow: { [weak self] in
                self?.showMainWindow()
            },
            onOpenSettings: { [weak self] in
                self?.showMainWindow(settings: true)
            },
            onVisibilityChange: { [batteryMonitor] visible in
                batteryMonitor.setPanelVisible(visible)
            }
        )
        statusItemController = StatusItemController(
            panelController: panelController,
            monitor: batteryMonitor,
            settings: settings,
            statusItem: statusItem
        )
        if let pendingSettings {
            self.pendingSettings = nil
            showMainWindow(settings: pendingSettings)
        }
    }

    /// 把设置页的“电量高于上限时”同步给 BatteryMonitor，设置变化时重新同步。
    private func syncChargeAboveLimitAction() {
        batteryMonitor?.holdsChargeAboveLimit = withObservationTracking {
            settings.chargeAboveLimitAction == .holdCurrentCharge
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncChargeAboveLimitAction() }
        }
    }

    /// 正在“保持当前电量”时写回用户设置的上限，见 docs/v1技术设计.md 第 6 节。
    func applicationWillTerminate(_ notification: Notification) {
        batteryMonitor?.restoreChargeLimitBeforeExit()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    private func showMainWindow(settings showSettings: Bool = false) {
        guard let batteryMonitor else {
            pendingSettings = showSettings
            return
        }
        let controller = mainWindowController ?? MainWindowController(
            history: HistoryModel(store: historyStore),
            monitor: batteryMonitor,
            settings: settings,
            alerts: alertMonitor,
            updates: updateController
        )
        mainWindowController = controller
        if showSettings { controller.showSettings() } else { controller.showAndActivate() }
    }

    /// 打开历史数据库。失败时只记录日志：照常显示实时读数，不写库。
    private nonisolated static func openHistoryStore() -> HistoryStore? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            logger.error("Missing bundle identifier, history disabled")
            return nil
        }
        do {
            return try HistoryStore(fileURL: HistoryStore.defaultFileURL(bundleIdentifier: bundleIdentifier))
        } catch {
            logger.error("Failed to open history database: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
