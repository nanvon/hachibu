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
    private(set) var recentRange: RecentRange = .day
    private(set) var longTermRange: LongTermRange = .month
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
    /// 所有来源中最早的一天，用于长期曲线的“未记录”区间。
    @ObservationIgnored private var firstDailyDay: String?

    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// 切换范围时可能有多个查询同时进行，只保留最后一次发起的结果。
    @ObservationIgnored private var recentGeneration = 0
    @ObservationIgnored private var longTermGeneration = 0

    public init(store: HistoryStore?) {
        self.store = store
        isAvailable = store != nil
        importer = store.map { HistoryImportModel(store: $0) }
        importer?.onChange = { [weak self] in
            await self?.reloadAll()
        }
    }

    /// 立即查询一次，之后每分钟刷新。重复调用无效果。
    public func start() {
        guard store != nil, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reloadAll()
                try? await Task.sleep(for: Self.refreshInterval, tolerance: .seconds(5))
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func setRecentRange(_ range: RecentRange) {
        guard range != recentRange else { return }
        recentRange = range
        Task { await loadRecent() }
    }

    func setLongTermRange(_ range: LongTermRange) {
        guard range != longTermRange else { return }
        longTermRange = range
        Task { await loadLongTerm() }
    }

    // MARK: - 查询

    func reloadAll() async {
        // 两组的“未记录”区间要用最早记录时间和记录概况，先查。
        await loadSummary()
        await loadRecent()
        await loadLongTerm()
    }

    private func loadSummary() async {
        guard let store else { return }
        do {
            let summary = try await store.recordingSummary()
            let lastUpdated = try await store.latestMinuteSampleTime()
            firstRecordedAt = try await store.firstSampleTime()
            firstDailyDay = try await store.firstDailyHealthDay()
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
        let range = recentRange
        let now = Date()
        let start = now.addingTimeInterval(-range.duration)
        do {
            let data: RecentChartData
            switch range {
            case .hour, .day:
                let samples = try await store.minuteSamples(from: start, to: now)
                data = HistoryChartBuilder.recent(minuteSamples: samples, range: range, now: now, firstRecordedAt: firstRecordedAt)
            case .week:
                let samples = try await store.minuteSamplesByHour(from: start, to: now)
                data = HistoryChartBuilder.recent(hourlyAverages: samples, range: range, now: now, firstRecordedAt: firstRecordedAt)
            }
            guard generation == recentGeneration else { return }
            recent = data
        } catch {
            logger.error("Failed to load recent history: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadLongTerm() async {
        guard let store else { return }
        longTermGeneration += 1
        let generation = longTermGeneration
        let range = longTermRange
        let now = Date()
        do {
            let samples = try await store.dailyHealth(from: HistoryChartBuilder.longTermFirstDay(range: range, now: now))
            let data = HistoryChartBuilder.longTerm(
                dailySamples: samples,
                range: range,
                now: now,
                firstRecordedDay: firstDailyDay
            )
            guard generation == longTermGeneration else { return }
            longTerm = data
        } catch {
            logger.error("Failed to load long-term history: \(String(describing: error), privacy: .public)")
        }
    }
}
