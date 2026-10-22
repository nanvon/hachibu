import AppKit
import FeatureUI
import HistoryStore
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let batteryMonitor = BatteryMonitor(sampler: BatterySampler(store: AppDelegate.openHistoryStore()))
    private var statusItemController: StatusItemController?
    private lazy var mainWindowController = MainWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        batteryMonitor.start()

        let panelController = PanelController(
            monitor: batteryMonitor,
            onOpenMainWindow: { [weak self] in
                self?.mainWindowController.showAndActivate()
            },
            onVisibilityChange: { [batteryMonitor] visible in
                batteryMonitor.setPanelVisible(visible)
            }
        )
        statusItemController = StatusItemController(panelController: panelController)
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
