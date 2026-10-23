import Foundation
import HistoryStore

/// 曲线上的一个点。`segment` 相同的点连成一条线，遇到缺失值或缺口时换新的一段。
struct ChartPoint: Identifiable, Equatable {
    var date: Date
    var value: Double
    var segment: Int

    var id: Date { date }
}

/// 近期组的时间范围。
enum RecentRange: CaseIterable, Hashable {
    case hour, day, week

    var duration: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }

    /// 1 小时、24 小时画分钟原始点，7 天按小时汇总。
    var sampleInterval: TimeInterval {
        self == .week ? 3600 : 60
    }
}

/// 长期组的时间范围。
enum LongTermRange: CaseIterable, Hashable {
    case month, year, all

    /// 显示的天数，含今天。`all` 从第一条记录开始。
    var dayCount: Int? {
        switch self {
        case .month: 30
        case .year: 365
        case .all: nil
        }
    }
}

/// 近期组三条曲线的数据。
struct RecentChartData: Equatable {
    var domain: ClosedRange<Date>
    /// 超过该间隔的相邻两点不连线；悬停时也只取这个距离内的点。
    var maxGap: TimeInterval
    /// 早于第一条记录的区间，标“未记录”。
    var notRecorded: Range<Date>?
    /// 接电时段，画底色。
    var pluggedIn: [Range<Date>]
    var percent: [ChartPoint]
    var systemPowerWatts: [ChartPoint]
    var temperatureCelsius: [ChartPoint]
}

/// 长期组三条曲线的数据。
struct LongTermChartData: Equatable {
    var domain: ClosedRange<Date>
    var maxGap: TimeInterval
    /// 早于第一条记录的区间，标“未记录”。
    var notRecorded: Range<Date>?
    var maximumCapacityPercent: [ChartPoint]
    var fullChargeCapacityMAh: [ChartPoint]
    var cycleCount: [ChartPoint]
}

/// 把数据库记录转换成曲线数据。规则见 docs/v1技术设计.md 第 11 节。
enum HistoryChartBuilder {
    /// 相邻两点间隔超过 3 个采样周期时断开曲线。
    static let maxGapIntervals: Double = 3

    private struct RecentRow {
        var date: Date
        var percent: Double?
        var systemLoadMW: Double?
        var temperatureCelsius: Double?
        var isExternalPower: Bool
    }

    // MARK: - 近期

    /// 1 小时、24 小时：分钟原始点。`firstRecordedAt` 晚于范围起点时，之前的区间标“未记录”。
    static func recent(minuteSamples: [MinuteSample], range: RecentRange, now: Date, firstRecordedAt: Date?) -> RecentChartData {
        let rows = minuteSamples.map { sample in
            RecentRow(
                date: sample.timestamp,
                percent: sample.percent.map(Double.init),
                systemLoadMW: sample.systemLoadMW.map(Double.init),
                temperatureCelsius: sample.temperatureCelsius,
                isExternalPower: sample.isExternalPower == true
            )
        }
        return recent(rows: rows, range: range, now: now, firstRecordedAt: firstRecordedAt)
    }

    /// 7 天：分钟数据按小时汇总后的平均值。一小时内接电分钟数过半算作接电。
    static func recent(hourlySamples: [HourlySample], range: RecentRange, now: Date, firstRecordedAt: Date?) -> RecentChartData {
        let rows = hourlySamples.map { sample in
            RecentRow(
                date: sample.hour,
                percent: sample.percentAverage,
                systemLoadMW: sample.systemLoadAverageMW,
                temperatureCelsius: sample.temperatureAverageCelsius,
                isExternalPower: sample.externalMinutes > 0 && sample.externalMinutes * 2 >= sample.sampleCount
            )
        }
        return recent(rows: rows, range: range, now: now, firstRecordedAt: firstRecordedAt)
    }

    private static func recent(rows: [RecentRow], range: RecentRange, now: Date, firstRecordedAt: Date?) -> RecentChartData {
        let domain = now.addingTimeInterval(-range.duration)...now
        let rows = rows.filter { domain.contains($0.date) }
        let maxGap = range.sampleInterval * maxGapIntervals
        return RecentChartData(
            domain: domain,
            maxGap: maxGap,
            notRecorded: notRecordedRange(in: domain, recordStart: firstRecordedAt),
            pluggedIn: intervals(
                rows.map { ($0.date, $0.isExternalPower) },
                sampleInterval: range.sampleInterval,
                maxGap: maxGap,
                end: domain.upperBound
            ),
            percent: segmented(rows.map { ($0.date, $0.percent) }, maxGap: maxGap),
            systemPowerWatts: segmented(rows.map { ($0.date, $0.systemLoadMW.map { $0 / 1000 }) }, maxGap: maxGap),
            temperatureCelsius: segmented(rows.map { ($0.date, $0.temperatureCelsius) }, maxGap: maxGap)
        )
    }

    // MARK: - 长期

    /// 查询 `daily_samples` 的起始日期。`all` 返回 nil，查询全部。
    static func longTermFirstDay(range: LongTermRange, now: Date, calendar: Calendar = .current) -> String? {
        guard let dayCount = range.dayCount else { return nil }
        return DailySample.day(for: firstDay(dayCount: dayCount, now: now, calendar: calendar), calendar: calendar)
    }

    /// 每天一个点，画在当天正午。横轴从范围第一天的 0 点到明天 0 点；
    /// `firstRecordedDay` 晚于范围起点时，之前的区间标“未记录”，横轴不缩短。
    static func longTerm(
        dailySamples: [DailySample],
        range: LongTermRange,
        now: Date,
        firstRecordedDay: String?,
        calendar: Calendar = .current
    ) -> LongTermChartData {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(24 * 3600)
        let firstRecordedStart = firstRecordedDay.flatMap { startOfDay($0, calendar: calendar) }
        let start = if let dayCount = range.dayCount {
            firstDay(dayCount: dayCount, now: now, calendar: calendar)
        } else {
            min(firstRecordedStart ?? today, today)
        }
        let domain = start...end

        let days: [(date: Date, sample: DailySample)] = dailySamples.compactMap { sample in
            guard let dayStart = startOfDay(sample.day, calendar: calendar) else { return nil }
            return (dayStart.addingTimeInterval(12 * 3600), sample)
        }
        .filter { domain.contains($0.date) }

        // 夏令时切换的日子不是 24 小时，留 1 小时余量。
        let maxGap = 24 * 3600 * maxGapIntervals + 3600
        return LongTermChartData(
            domain: domain,
            maxGap: maxGap,
            notRecorded: notRecordedRange(in: domain, recordStart: firstRecordedStart),
            maximumCapacityPercent: segmented(days.map { ($0.date, $0.sample.systemMaxCapacityPercent.map(Double.init)) }, maxGap: maxGap),
            fullChargeCapacityMAh: segmented(days.map { ($0.date, $0.sample.fullChargeCapacityMAh.map(Double.init)) }, maxGap: maxGap),
            cycleCount: segmented(days.map { ($0.date, $0.sample.cycleCount.map(Double.init)) }, maxGap: maxGap)
        )
    }

    private static func firstDay(dayCount: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
    }

    /// 解析 `YYYY-MM-DD`，返回当天 0 点。格式不符时为 nil。
    static func startOfDay(_ day: String, calendar: Calendar = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    // MARK: - 通用

    /// 横轴起点到 `recordStart` 的区间。`recordStart` 不晚于起点或没有记录时为 nil。
    static func notRecordedRange(in domain: ClosedRange<Date>, recordStart: Date?) -> Range<Date>? {
        guard let recordStart, recordStart > domain.lowerBound else { return nil }
        return domain.lowerBound..<min(recordStart, domain.upperBound)
    }

    /// 按时间顺序生成曲线点。缺失值不画；缺失值之后或相邻间隔超过 `maxGap` 时开始新的一段。
    static func segmented(_ values: [(date: Date, value: Double?)], maxGap: TimeInterval) -> [ChartPoint] {
        var points: [ChartPoint] = []
        var segment = 0
        var previousDate: Date?
        for (date, value) in values {
            guard let value else {
                if previousDate != nil {
                    segment += 1
                }
                previousDate = nil
                continue
            }
            if let previousDate, date.timeIntervalSince(previousDate) > maxGap {
                segment += 1
            }
            points.append(ChartPoint(date: date, value: value, segment: segment))
            previousDate = date
        }
        return points
    }

    /// 连续为 true 的区间。每个样本覆盖 `[date, date + sampleInterval)`，间隔超过 `maxGap` 时断开，结束时间不超过 `end`。
    static func intervals(
        _ flags: [(date: Date, isOn: Bool)],
        sampleInterval: TimeInterval,
        maxGap: TimeInterval,
        end: Date
    ) -> [Range<Date>] {
        var result: [Range<Date>] = []
        var current: (start: Date, last: Date)?

        func close() {
            if let current {
                result.append(current.start..<max(current.start, min(current.last.addingTimeInterval(sampleInterval), end)))
            }
            current = nil
        }

        for (date, isOn) in flags {
            guard isOn else {
                close()
                continue
            }
            if let run = current, date.timeIntervalSince(run.last) <= maxGap {
                current = (run.start, date)
            } else {
                close()
                current = (date, date)
            }
        }
        close()
        return result
    }

    /// 离 `date` 最近的点，距离超过 `maxDistance` 时为 nil。`points` 按时间排序。
    static func nearest(in points: [ChartPoint], to date: Date, within maxDistance: TimeInterval) -> ChartPoint? {
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let best = [low - 1, low]
            .filter { points.indices.contains($0) }
            .map { points[$0] }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        guard let best, abs(best.date.timeIntervalSince(date)) <= maxDistance else { return nil }
        return best
    }
}
