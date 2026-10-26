import Foundation
import HistoryStore
import Observation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "HistoryImport")

/// 设置页“历史数据”分区：导入文件、列出和删除已导入的来源。流程见 docs/v1技术设计.md 20.6。
/// 选择文件由 App 层负责；解析在后台执行，写入在 HistoryStore 的事务里。
@MainActor
@Observable
public final class HistoryImportModel {
    enum Failure: Equatable {
        case invalidFile(HistoryImportError)
        case unreadable
        case writeFailed
    }

    private(set) var sources: [ImportedSource] = []
    /// 等待用户确认的导入。
    private(set) var pending: HistoryImportPreview?
    private(set) var failure: Failure?
    private(set) var isWorking = false

    /// 导入或删除之后调用，用来刷新历史曲线。
    @ObservationIgnored var onChange: (@MainActor () async -> Void)?
    @ObservationIgnored private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
    }

    func loadSources() async {
        do {
            let sources = try await store.importedSources()
            if sources != self.sources {
                self.sources = sources
            }
        } catch {
            logger.error("Failed to load imported sources: \(String(describing: error), privacy: .public)")
        }
    }

    /// 读取并解析文件，成功后等待确认。
    func prepare(fileURL: URL) async {
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                try Self.parse(fileURL)
            }.value
            pending = try await store.previewImport(file)
        } catch let error as HistoryImportError {
            failure = .invalidFile(error)
        } catch {
            logger.error("Failed to read import file: \(String(describing: error), privacy: .public)")
            failure = .unreadable
        }
    }

    /// 使用确认框捕获的预览，避免关闭确认框清空 pending 后丢失导入内容。
    func confirmImport(_ preview: HistoryImportPreview) async {
        pending = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.importHistory(preview.file)
        } catch let error as HistoryImportError {
            failure = .invalidFile(error)
            return
        } catch {
            logger.error("Failed to import history: \(String(describing: error), privacy: .public)")
            failure = .writeFailed
            return
        }
        await loadSources()
        await onChange?()
    }

    func cancelImport() {
        pending = nil
    }

    func delete(_ source: ImportedSource) async {
        failure = nil
        do {
            try await store.deleteImportedSource(id: source.id)
        } catch {
            logger.error("Failed to delete imported source: \(String(describing: error), privacy: .public)")
            failure = .writeFailed
        }
        await loadSources()
        await onChange?()
    }

    /// 先看文件大小，避免把过大的文件读进内存。
    private nonisolated static func parse(_ url: URL) throws -> HistoryImportFile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= HistoryImportFile.maximumFileSize else { throw HistoryImportError.fileTooLarge }
        return try HistoryImportFile.parse(Data(contentsOf: url))
    }
}
