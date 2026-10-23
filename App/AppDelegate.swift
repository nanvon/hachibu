import AppKit
import FeatureUI
import HistoryStore
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let historyStore: HistoryStore?
    private let batteryMonitor: BatteryMonitor
    private let settings = AppSettings()
    private lazy var alertMonitor = AlertMonitor(settings: settings, notifier: SystemAlertNotifier())
    private let updateController = UpdateController()
    private var statusItemController: StatusItemController?
    private lazy var mainWindowController = MainWindowController(
        history: HistoryModel(store: historyStore),
        monitor: batteryMonitor,
        settings: settings,
        alerts: alertMonitor,
        updates: updateController
    )

    override init() {
        historyStore = Self.openHistoryStore()
        batteryMonitor = BatteryMonitor(sampler: BatterySampler(store: historyStore))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        batteryMonitor.onRead = { [alertMonitor] reading, date in
            alertMonitor.handleReading(reading, at: date)
        }
        batteryMonitor.onHealthRefresh = { [alertMonitor] health in
            alertMonitor.handleHealth(health)
        }
        alertMonitor.start()
        batteryMonitor.start()

        let panelController = PanelController(
            monitor: batteryMonitor,
            settings: settings,
            onOpenMainWindow: { [weak self] in
                self?.mainWindowController.showAndActivate()
            },
            onVisibilityChange: { [batteryMonitor] visible in
                batteryMonitor.setPanelVisible(visible)
            }
        )
        statusItemController = StatusItemController(
            panelController: panelController,
            monitor: batteryMonitor,
            settings: settings
        )
    }

    /// 打开历史数据库。失败时只记录日志：照常显示实时读数，不写库。
    private static func openHistoryStore() -> HistoryStore? {
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
