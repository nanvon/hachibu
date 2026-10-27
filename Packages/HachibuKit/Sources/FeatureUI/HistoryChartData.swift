import Foundation
import HistoryStore

/// 曲线上的一个点。`segment` 相同的点连成一条线，遇到缺失值或缺口时换新的一段。
struct ChartPoint: Identifiable, Equatable, Sendable {
    var date: Date
    var value: Double
    var segment: Int

    var id: Date { date }
}

/// 正负分开着色的曲线中同号的一段，见 `HistoryChartBuilder.signedRuns(_:)`。
struct SignedRun: Identifiable, Equatable {
    var id: Int
    var isPositive: Bool
    var points: [ChartPoint]
}

/// 原始点用于读数和悬停；绘图点在加载时生成，避免鼠标移动时重复降采样。
struct ChartSeries: Equatable, Sendable {
    let points: [ChartPoint]
    let plotPoints: [ChartPoint]
    let plotID = UUID()

    init(_ points: [ChartPoint]) {
        self.points = points
        plotPoints = HistoryChartBuilder.downsample(points)
    }

    /// 没有悬停时显示最新值；悬停时只读选中时刻，缺失值不借用其他时刻。
    func reading(at selection: Date?) -> ChartPoint? {
        guard let selection else { return points.last }
        return HistoryChartBuilder.nearest(in: points, to: selection, within: 0)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.plotPoints == rhs.plotPoints
    }
}

/// 近期组六条曲线的数据。
struct RecentChartData: Equatable, Sendable {
    var hoverPoints: [ChartPoint]
    var domain: ClosedRange<Date>
    /// 超过该间隔的相邻两点不连线；悬停时也只取这个距离内的点。
    var maxGap: TimeInterval
    /// 早于第一条记录的区间，标“未记录”。
    var notRecorded: Range<Date>?
    /// 插电时段，画底色。
    var pluggedIn: [Range<Date>]
    var percent: ChartSeries
    var temperatureCelsius: ChartSeries
    var systemPowerWatts: ChartSeries
    /// 电池功率，充电为正、放电为负。
    var batteryPowerWatts: ChartSeries
    var powerInWatts: ChartSeries
    var voltageVolts: ChartSeries
    /// 系统充电上限（关闭时为 100），阶梯线的转折点；没有记录时为空。
    var chargeLimitPercent: ChartSeries
    var stats: RecentStats
}

/// 近期组图下方的统计。每条分钟样本计 1 分钟。
struct RecentStats: Equatable, Sendable {
    var pluggedInMinutes: Int
    var chargingMinutes: Int
    /// 48 小时里没有分钟样本的时间，包括休眠和“未记录”区间。
    var notRecordedMinutes: Int
    var highestTemperature: ChartPoint?
    var lowestTemperature: ChartPoint?
    var averageTemperature: Double?
}

/// 长期组四条曲线的数据。
struct LongTermChartData: Equatable, Sendable {
    var hoverPoints: [ChartPoint]
    var domain: ClosedRange<Date>
    var maxGap: TimeInterval
    /// 早于第一条记录的区间，标“未记录”。
    var notRecorded: Range<Date>?
    var maximumCapacityPercent: ChartSeries
    /// 容量比：满充容量 / 设计容量，百分数。两者任一缺失时该天没有点。
    var capacityRatioPercent: ChartSeries
    var fullChargeCapacityMAh: ChartSeries
    /// 满充容量的 14 天滑动平均，作为满充容量图的主线。
    var fullChargeTrend: ChartSeries
    var cycleCount: ChartSeries
    /// 最近一天的设计容量，用于满充容量图的最小纵轴跨度。
    var designCapacityMAh: Int?
    /// 记录满 60 天后的变化趋势，不足时为 nil。
    var trend: HealthTrend?
    /// 平均每月循环次数，记录不足 30 天时为 nil。
    var cyclesPerMonth: Double?
}

/// 电池健康块标题下的结论：最早 30 天和最近 30 天满充容量平均值的变化，以及循环次数的起止值。
struct HealthTrend: Equatable, Sendable {
    var months: Int
    var earlyFullChargeMAh: Double
    var lateFullChargeMAh: Double
    var firstCycleCount: Int?
    var lastCycleCount: Int?

    var fullChargeChangeMAh: Int { Int(lateFullChargeMAh.rounded()) - Int(earlyFullChargeMAh.rounded()) }
    var fullChargeChangeRatio: Double { (lateFullChargeMAh - earlyFullChargeMAh) / earlyFullChargeMAh }
}

/// 把数据库记录转换成曲线数据。规则见 docs/v1技术设计.md 第 11 节。
enum HistoryChartBuilder {
    static let recentDuration: TimeInterval = 48 * 3600
    static let sampleInterval: TimeInterval = 60

    /// 相邻两点间隔超过 3 个采样周期时断开曲线。
    static let maxGapIntervals: Double = 3

    private struct RecentRow {
        var date: Date
        var percent: Double?
        var systemLoadMW: Double?
        var batteryPowerMW: Double?
        var powerInMW: Double?
        var temperatureCelsius: Double?
        var voltageMV: Double?
        var isExternalPower: Bool
        var isCharging: Bool
    }

    // MARK: - 近期

    /// 固定最近 48 小时：分钟原始点。`firstRecordedAt` 晚于范围起点时，之前的区间标“未记录”。
    /// `chargeLimitEvents` 为全部 `charge_limit` 事件，按时间排序。
    static func recent(
        minuteSamples: [MinuteSample],
        chargeLimitEvents: [BatteryEvent] = [],
        now: Date,
        firstRecordedAt: Date?
    ) -> RecentChartData {
        let rows = minuteSamples.map { sample in
            RecentRow(
                date: sample.timestamp,
                percent: sample.percent.map(Double.init),
                systemLoadMW: sample.systemLoadMW.map(Double.init),
                batteryPowerMW: sample.batteryPowerMW.map(Double.init),
                powerInMW: sample.powerInMW.map(Double.init),
                temperatureCelsius: sample.temperatureCelsius,
                voltageMV: sample.voltageMV.map(Double.init),
                isExternalPower: sample.isExternalPower == true,
                isCharging: sample.isCharging == true
            )
        }
        return recent(rows: rows, chargeLimitEvents: chargeLimitEvents, now: now, firstRecordedAt: firstRecordedAt)
    }

    private static func recent(rows: [RecentRow], chargeLimitEvents: [BatteryEvent], now: Date, firstRecordedAt: Date?) -> RecentChartData {
        let domain = now.addingTimeInterval(-recentDuration)...now
        let rows = rows.filter { domain.contains($0.date) }
        let maxGap = sampleInterval * maxGapIntervals
        let temperatures = rows.compactMap { row in row.temperatureCelsius.map { ChartPoint(date: row.date, value: $0, segment: 0) } }
        let stats = RecentStats(
            pluggedInMinutes: rows.count { $0.isExternalPower },
            chargingMinutes: rows.count { $0.isCharging },
            notRecordedMinutes: max(0, Int(recentDuration / sampleInterval) - rows.count),
            highestTemperature: temperatures.max { $0.value < $1.value },
            lowestTemperature: temperatures.min { $0.value < $1.value },
            averageTemperature: temperatures.isEmpty ? nil : temperatures.reduce(0) { $0 + $1.value } / Double(temperatures.count)
        )
        return RecentChartData(
            hoverPoints: rows.map { ChartPoint(date: $0.date, value: 0, segment: 0) },
            domain: domain,
            maxGap: maxGap,
            notRecorded: notRecordedRange(in: domain, recordStart: firstRecordedAt),
            pluggedIn: intervals(
                rows.map { ($0.date, $0.isExternalPower) },
                sampleInterval: sampleInterval,
                maxGap: maxGap,
                end: domain.upperBound
            ),
            percent: ChartSeries(segmented(rows.map { ($0.date, $0.percent) }, maxGap: maxGap)),
            temperatureCelsius: ChartSeries(segmented(rows.map { ($0.date, $0.temperatureCelsius) }, maxGap: maxGap)),
            systemPowerWatts: ChartSeries(segmented(rows.map { ($0.date, $0.systemLoadMW.map { $0 / 1000 }) }, maxGap: maxGap)),
            batteryPowerWatts: ChartSeries(segmented(rows.map { ($0.date, $0.batteryPowerMW.map { $0 / 1000 }) }, maxGap: maxGap)),
            powerInWatts: ChartSeries(segmented(rows.map { ($0.date, $0.powerInMW.map { $0 / 1000 }) }, maxGap: maxGap)),
            voltageVolts: ChartSeries(segmented(rows.map { ($0.date, $0.voltageMV.map { $0 / 1000 }) }, maxGap: maxGap)),
            chargeLimitPercent: ChartSeries(chargeLimitSteps(chargeLimitEvents, in: domain)),
            stats: stats
        )
    }

    /// 充电上限阶梯线的转折点：范围起点取起点之前最后一条事件的值，之后每条事件一个点，最后补到范围终点。
    /// 范围内外都没有事件时为空。
    static func chargeLimitSteps(_ events: [BatteryEvent], in domain: ClosedRange<Date>) -> [ChartPoint] {
        var points: [ChartPoint] = []
        if let initial = events.last(where: { $0.date <= domain.lowerBound })?.value {
            points.append(ChartPoint(date: domain.lowerBound, value: Double(initial), segment: 0))
        }
        for event in events where event.date > domain.lowerBound && event.date <= domain.upperBound {
            guard let value = event.value else { continue }
            points.append(ChartPoint(date: event.date, value: Double(value), segment: 0))
        }
        if let last = points.last, last.date < domain.upperBound {
            points.append(ChartPoint(date: domain.upperBound, value: last.value, segment: 0))
        }
        return points
    }

    // MARK: - 长期

    /// 全部每日数据，每天一个点，画在当天正午。横轴从最早记录当天 0 点到明天 0 点。
    static func longTerm(
        dailySamples: [DailyHealth],
        now: Date,
        firstRecordedDay: String?,
        calendar: Calendar = .current
    ) -> LongTermChartData {
        let calendar = DailyHealth.gregorianCalendar(timeZone: calendar.timeZone)
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(24 * 3600)
        let firstRecordedStart = firstRecordedDay.flatMap { startOfDay($0, calendar: calendar) }
        let start = min(firstRecordedStart ?? today, today)
        let domain = start...end

        let days: [(date: Date, sample: DailyHealth)] = dailySamples.compactMap { sample in
            guard let dayStart = startOfDay(sample.day, calendar: calendar) else { return nil }
            return (dayStart.addingTimeInterval(12 * 3600), sample)
        }
        .filter { domain.contains($0.date) }

        // 夏令时切换的日子不是 24 小时，留 1 小时余量。
        let maxGap = 24 * 3600 * maxGapIntervals + 3600
        let fullCharge = segmented(days.map { ($0.date, $0.sample.fullChargeCapacityMAh.map(Double.init)) }, maxGap: maxGap)
        let cycles = segmented(days.map { ($0.date, $0.sample.cycleCount.map(Double.init)) }, maxGap: maxGap)
        return LongTermChartData(
            hoverPoints: days.map { ChartPoint(date: $0.date, value: 0, segment: 0) },
            domain: domain,
            maxGap: maxGap,
            notRecorded: notRecordedRange(in: domain, recordStart: firstRecordedStart),
            maximumCapacityPercent: ChartSeries(segmented(days.map { ($0.date, $0.sample.systemMaxCapacityPercent.map(Double.init)) }, maxGap: maxGap)),
            capacityRatioPercent: ChartSeries(segmented(days.map { ($0.date, capacityRatioPercent($0.sample)) }, maxGap: maxGap)),
            fullChargeCapacityMAh: ChartSeries(fullCharge),
            fullChargeTrend: ChartSeries(rollingAverage(fullCharge)),
            cycleCount: ChartSeries(cycles),
            designCapacityMAh: days.last { $0.sample.designCapacityMAh != nil }?.sample.designCapacityMAh,
            trend: healthTrend(fullCharge: fullCharge, cycles: cycles),
            cyclesPerMonth: cyclesPerMonth(cycles)
        )
    }

    static let trendWindow: TimeInterval = 14 * 86400
    static let trendMinimumPoints = 5
    static let comparisonWindow: TimeInterval = 30 * 86400
    static let averageMonth: TimeInterval = 30.44 * 86400

    /// 14 天滑动平均：每个点取它之前 14 天内（含当天）的读数，少于 5 个时不画。保留原来的分段。
    static func rollingAverage(_ points: [ChartPoint]) -> [ChartPoint] {
        var result: [ChartPoint] = []
        var lower = 0
        var sum = 0.0
        for (index, point) in points.enumerated() {
            sum += point.value
            while point.date.timeIntervalSince(points[lower].date) >= trendWindow {
                sum -= points[lower].value
                lower += 1
            }
            let count = index - lower + 1
            if count >= trendMinimumPoints {
                result.append(ChartPoint(date: point.date, value: sum / Double(count), segment: point.segment))
            }
        }
        return result
    }

    /// 最早 30 天和最近 30 天的满充容量平均值。首尾相隔不足 60 天、或任一窗口少于 5 个读数时为 nil。
    static func healthTrend(fullCharge: [ChartPoint], cycles: [ChartPoint]) -> HealthTrend? {
        guard let first = fullCharge.first?.date, let last = fullCharge.last?.date,
              last.timeIntervalSince(first) >= 2 * comparisonWindow
        else { return nil }
        let early = fullCharge.filter { $0.date.timeIntervalSince(first) < comparisonWindow }.map(\.value)
        let late = fullCharge.filter { last.timeIntervalSince($0.date) < comparisonWindow }.map(\.value)
        guard early.count >= trendMinimumPoints, late.count >= trendMinimumPoints else { return nil }
        return HealthTrend(
            months: Int((last.timeIntervalSince(first) / averageMonth).rounded()),
            earlyFullChargeMAh: early.reduce(0, +) / Double(early.count),
            lateFullChargeMAh: late.reduce(0, +) / Double(late.count),
            firstCycleCount: cycles.first.map { Int($0.value) },
            lastCycleCount: cycles.last.map { Int($0.value) }
        )
    }

    /// 首尾两天的循环次数之差按月折算。相隔不足 30 天或次数减少（换过电池）时为 nil。
    static func cyclesPerMonth(_ cycles: [ChartPoint]) -> Double? {
        guard let first = cycles.first, let last = cycles.last, last.value >= first.value else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= comparisonWindow else { return nil }
        return (last.value - first.value) / (span / averageMonth)
    }

    private static func capacityRatioPercent(_ sample: DailyHealth) -> Double? {
        guard let fullCharge = sample.fullChargeCapacityMAh, let design = sample.designCapacityMAh, design > 0 else { return nil }
        return Double(fullCharge) / Double(design) * 100
    }

    /// 解析 `YYYY-MM-DD`，返回当天 0 点。格式不符时为 nil。
    static func startOfDay(_ day: String, calendar: Calendar = .current) -> Date? {
        let calendar = DailyHealth.gregorianCalendar(timeZone: calendar.timeZone)
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

    /// 正负分开着色的曲线：按正负切成若干段，跨过 0 时在两点间按线性插值补一个值为 0 的点，前后两段共用。
    /// 原来就断开的地方（`segment` 不同）仍然断开。0 算作正。
    static func signedRuns(_ points: [ChartPoint]) -> [SignedRun] {
        var runs: [SignedRun] = []
        var current: SignedRun?
        for point in points {
            let isPositive = point.value >= 0
            guard var run = current, let last = run.points.last, last.segment == point.segment else {
                if let current {
                    runs.append(current)
                }
                current = SignedRun(id: runs.count, isPositive: isPositive, points: [point])
                continue
            }
            if run.isPositive == isPositive {
                run.points.append(point)
                current = run
                continue
            }
            let fraction = last.value / (last.value - point.value)
            let zero = ChartPoint(
                date: last.date.addingTimeInterval(point.date.timeIntervalSince(last.date) * fraction),
                value: 0,
                segment: point.segment
            )
            run.points.append(zero)
            runs.append(run)
            current = SignedRun(id: runs.count, isPositive: isPositive, points: [zero, point])
        }
        if let current {
            runs.append(current)
        }
        return runs
    }

    /// 按连续段分桶，每桶保留首尾、最小及最大值，保持真实时间顺序。
    /// 连续数据约不超过 targetCount 个绘图点；缺口很多时优先保留每段端点，不跨缺口连线。
    static func downsample(_ points: [ChartPoint], targetCount: Int = 1200) -> [ChartPoint] {
        guard points.count > targetCount, targetCount >= 4 else { return points }
        let bucketSize = Int(ceil(Double(points.count) / Double(targetCount / 4)))
        var result: [ChartPoint] = []
        var start = 0
        while start < points.count {
            var end = start + 1
            while end < points.count, points[end].segment == points[start].segment {
                end += 1
            }
            for lower in stride(from: start, to: end, by: bucketSize) {
                let upper = min(lower + bucketSize, end)
                var minimum = lower
                var maximum = lower
                for index in lower..<upper {
                    if points[index].value < points[minimum].value { minimum = index }
                    if points[index].value > points[maximum].value { maximum = index }
                }
                for index in Set([lower, minimum, maximum, upper - 1]).sorted() {
                    result.append(points[index])
                }
            }
            start = end
        }
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
