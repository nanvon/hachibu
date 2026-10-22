import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private lazy var mainWindowController = MainWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()

        let panelController = PanelController(onOpenMainWindow: { [weak self] in
            self?.mainWindowController.showAndActivate()
        })
        statusItemController = StatusItemController(panelController: panelController)
    }
}
