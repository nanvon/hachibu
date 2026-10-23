import AppKit
import CryptoKit
import FeatureUI
import HistoryStore
import SwiftUI

/// 原始来源档案独立窗口；关闭时取消只读加载，保存位置由 AppKit 管理。
@MainActor
final class AlDenteHistoryWindowController: NSWindowController, NSWindowDelegate {
    private let store: HistoryStore
    private let model: AlDenteHistoryModel
    private var loadTask: Task<Void, Never>?

    init(store: HistoryStore) {
        self.store = store
        model = AlDenteHistoryModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = String(localized: "Imported AlDente History")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AlDenteHistoryWindow")
        if !window.setFrameUsingName("AlDenteHistoryWindow") { window.center() }
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AlDenteHistoryPage(model: model) { [weak self] identifier in
            await self?.exportOriginal(identifier: identifier)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showAndActivate() {
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        refreshIfVisible()
    }

    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.model.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
    }

    private func exportOriginal(identifier: String) async {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AlDente-History-\(identifier.prefix(12)).json"
        panel.message = String(localized: "Exports the complete original JSON, including battery identifiers.")
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
        do {
            guard let data = try await store.alDenteArchiveData(identifier: identifier) else {
                throw AlDenteHistoryError.archiveNotFound
            }
            try await Task.detached(priority: .userInitiated) {
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == identifier else { throw AlDenteHistoryError.invalidStoredRecord }
                try data.write(to: url, options: .atomic)
            }.value
        } catch {
            guard window.isVisible else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Could Not Export Archive")
            switch error {
            case AlDenteHistoryError.archiveNotFound:
                alert.informativeText = String(localized: "The imported archive could not be found.")
            case AlDenteHistoryError.invalidStoredRecord:
                alert.informativeText = String(localized: "The stored archive failed its integrity check. No file was exported.")
            default:
                alert.informativeText = error.localizedDescription
            }
            await alert.beginSheetModal(for: window)
        }
    }
}
