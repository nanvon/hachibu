import Foundation
import HistoryStore
import Observation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Hachibu", category: "History")

/// 主窗口历史曲线的数据。窗口显示期间每分钟重新查询一次，由 App 层在窗口打开、关闭时调用 `start()`、`stop()`。
@MainActor
@Observable
public final class HistoryModel {
    private static let refreshInterval: Duration = .seconds(60)

    /// 数据库打不开时为 false，页面显示不可用。
    let isAvailable: Bool
    /// 第一次查询完成前为 nil。
    private(set) var recent: RecentChartData?
    private(set) var longTerm: LongTermChartData?
    /// 最近一次分钟采样的时间。
    private(set) var lastUpdated: Date?
    private(set) var summary: RecordingSummary?
    /// 导入历史数据。数据库打不开时为 nil。
    let importer: HistoryImportModel?
    /// 最早一条分钟或小时数据的时间，用于近期曲线的“未记录”区间。
    @ObservationIgnored private var firstRecordedAt: Date?
    /// 每日记录不变且未跨日时复用长期曲线，避免每分钟重建全部历史。
    @ObservationIgnored private var cachedDailySamples: [DailyHealth]?
    @ObservationIgnored private var longTermDay: Date?

    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var isWindowVisible = false
    @ObservationIgnored private var isHistoryPageVisible = true
    /// 定时刷新与导入可能重叠，只保留最后一次发起的结果。
    @ObservationIgnored private var recentGeneration = 0
    @ObservationIgnored private var longTermGeneration = 0

    public init(store: HistoryStore?) {
        self.store = store
        isAvailable = store != nil
        importer = store.map { HistoryImportModel(store: $0) }
        importer?.onChange = { [weak self] in
            guard self?.refreshTask != nil else { return }
            await self?.reloadAll()
        }
    }

    /// 立即查询一次，之后每分钟刷新。重复调用无效果。
    public func start() {
        isWindowVisible = true
        updateRefreshActivity()
    }

    func setHistoryPageVisible(_ visible: Bool) {
        isHistoryPageVisible = visible
        updateRefreshActivity()
    }

    private func updateRefreshActivity() {
        guard isWindowVisible, isHistoryPageVisible else {
            stopRefreshing()
            return
        }
        guard store != nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reloadAll()
                try? await Task.sleep(for: Self.refreshInterval, tolerance: .seconds(5))
            }
        }
    }

    public func stop() {
        isWindowVisible = false
        stopRefreshing()
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        recentGeneration += 1
        longTermGeneration += 1
    }

    // MARK: - 查询

    func reloadAll() async {
        // 近期的“未记录”区间要用最早记录时间，先查。
        await loadSummary()
        guard !Task.isCancelled else { return }
        await loadRecent()
        guard !Task.isCancelled else { return }
        await loadLongTerm()
    }

    private func loadSummary() async {
        guard let store else { return }
        do {
            let summary = try await store.recordingSummary()
            let lastUpdated = try await store.latestMinuteSampleTime()
            firstRecordedAt = try await store.firstSampleTime()
            if summary != self.summary {
                self.summary = summary
            }
            if lastUpdated != self.lastUpdated {
                self.lastUpdated = lastUpdated
            }
        } catch {
            logger.error("Failed to load recording summary: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadRecent() async {
        guard let store else { return }
        recentGeneration += 1
        let generation = recentGeneration
        let now = Date()
        let firstRecordedAt = firstRecordedAt
        do {
            // 查询和点集转换均在后台执行，主线程只发布最终结果。
            let data = try await Task.detached(priority: .utility) {
                let samples = try await store.minuteSamples(from: now.addingTimeInterval(-HistoryChartBuilder.recentDuration), to: now)
                return HistoryChartBuilder.recent(minuteSamples: samples, now: now, firstRecordedAt: firstRecordedAt)
            }.value
            guard !Task.isCancelled, generation == recentGeneration else { return }
            recent = data
        } catch {
            logger.error("Failed to load recent history: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadLongTerm() async {
        guard let store else { return }
        longTermGeneration += 1
        let generation = longTermGeneration
        let now = Date()
        let today = DailyHealth.gregorianCalendar().startOfDay(for: now)
        let cachedSamples = cachedDailySamples
        let cachedDay = longTermDay
        do {
            let (samples, data) = try await Task.detached(priority: .utility) {
                let samples = try await store.dailyHealth()
                guard samples != cachedSamples || today != cachedDay else {
                    return (samples, nil as LongTermChartData?)
                }
                return (samples, HistoryChartBuilder.longTerm(
                    dailySamples: samples,
                    now: now,
                    firstRecordedDay: samples.first?.day
                ))
            }.value
            guard !Task.isCancelled, generation == longTermGeneration else { return }
            if let data {
                cachedDailySamples = samples
                longTermDay = today
                longTerm = data
            }
        } catch {
            logger.error("Failed to load long-term history: \(String(describing: error), privacy: .public)")
        }
    }
}
