import Foundation
import HistoryStore

/// 曲线上的一个点。所有点连成一条线，缺失值和缺口处直接连到下一个点。
struct ChartPoint: Identifiable, Equatable, Sendable {
    var date: Date
    var value: Double

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

    /// 绘图点另行指定，例如功率曲线只画抽稀后的点。
    init(_ points: [ChartPoint], plotPoints: [ChartPoint]) {
        self.points = points
        self.plotPoints = plotPoints
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
    /// 超过该间隔的相邻样本不算同一段插电；悬停位置在首尾采样之外时，只取这个距离内的点。
    var maxGap: TimeInterval
    /// 早于第一条记录的区间，标“未记录”。
    var notRecorded: Range<Date>?
    /// 插电时段，画底色。
    var pluggedIn: [Range<Date>]
    /// 系统充电策略时段（系统校准、优化充电、临时充满等，不含其他充电工具），已合并，只画电量图。
    var systemPolicy: [Range<Date>] = []
    /// Hachibu 电池校准时段，只画电量图。
    var calibration: [Range<Date>] = []
    var percent: ChartSeries
    var temperatureCelsius: ChartSeries
    /// 系统功率的滑动平均，见 `HistoryChartBuilder.powerSeries(_:)`。
    var systemPowerWatts: ChartSeries
    /// 电池功率的滑动平均，充电为正、放电为负。
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
    /// 悬停位置在首尾采样之外时，只取这个距离内的点。
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
    /// 完成过电池校准的日子（画在当天正午，与每日点对齐），满充容量图上标出。
    var calibrationDays: [Date] = []
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

    /// 插电底色的连续判断和悬停范围外的容差：3 个采样周期。曲线不受它影响。
    static let maxGapIntervals: Double = 3

    /// 功率曲线的平均窗口：以每个样本为中心，前后各取一半。
    static let powerAverageWindow: TimeInterval = 15 * 60
    /// 功率曲线的绘图点间隔，读数和悬停仍用每个分钟样本。
    static let powerPlotInterval: TimeInterval = 5 * 60
    /// 功率曲线只保留至少这么多个连续样本的片段。睡眠期间系统定时唤醒，每次只记下 1–3 条样本，
    /// 它们当作睡眠的一部分，不画也不读，避免把一整夜切成很多段。
    static let powerMinimumRunSamples = 5
    /// 功率图里超过这个间隔的缺口画淡色直虚线：睡眠时功率接近 0，实线连过去会像一直在耗电。
    static let powerDashedGap: TimeInterval = 30 * 60

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
        policyPeriods: [ChargePolicyPeriod] = [],
        calibrationRuns: [CalibrationRun] = [],
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
        return recent(
            rows: rows, chargeLimitEvents: chargeLimitEvents, policyPeriods: policyPeriods, calibrationRuns: calibrationRuns,
            now: now, firstRecordedAt: firstRecordedAt
        )
    }

    private static func recent(
        rows: [RecentRow],
        chargeLimitEvents: [BatteryEvent],
        policyPeriods: [ChargePolicyPeriod],
        calibrationRuns: [CalibrationRun],
        now: Date,
        firstRecordedAt: Date?
    ) -> RecentChartData {
        let domain = now.addingTimeInterval(-recentDuration)...now
        let rows = rows.filter { domain.contains($0.date) }
        let maxGap = sampleInterval * maxGapIntervals
        let temperatures = rows.compactMap { row in row.temperatureCelsius.map { ChartPoint(date: row.date, value: $0) } }
        let stats = RecentStats(
            pluggedInMinutes: rows.count { $0.isExternalPower },
            chargingMinutes: rows.count { $0.isCharging },
            notRecordedMinutes: max(0, Int(recentDuration / sampleInterval) - rows.count),
            highestTemperature: temperatures.max { $0.value < $1.value },
            lowestTemperature: temperatures.min { $0.value < $1.value },
            averageTemperature: temperatures.isEmpty ? nil : temperatures.reduce(0) { $0 + $1.value } / Double(temperatures.count)
        )
        return RecentChartData(
            hoverPoints: rows.map { ChartPoint(date: $0.date, value: 0) },
            domain: domain,
            maxGap: maxGap,
            notRecorded: notRecordedRange(in: domain, recordStart: firstRecordedAt),
            pluggedIn: intervals(
                rows.map { ($0.date, $0.isExternalPower) },
                sampleInterval: sampleInterval,
                maxGap: maxGap,
                end: domain.upperBound
            ),
            systemPolicy: mergedRanges(
                policyPeriods.filter { $0.kind != .otherTool }.map { ($0.start, $0.end) }, in: domain
            ),
            calibration: mergedRanges(calibrationRuns.map { ($0.startedAt, $0.endedAt) }, in: domain),
            percent: ChartSeries(linePoints(rows.map { ($0.date, $0.percent) })),
            temperatureCelsius: ChartSeries(linePoints(rows.map { ($0.date, $0.temperatureCelsius) })),
            systemPowerWatts: powerSeries(linePoints(rows.map { ($0.date, $0.systemLoadMW.map { $0 / 1000 }) })),
            batteryPowerWatts: powerSeries(linePoints(rows.map { ($0.date, $0.batteryPowerMW.map { $0 / 1000 }) })),
            powerInWatts: ChartSeries(linePoints(rows.map { ($0.date, $0.powerInMW.map { $0 / 1000 }) })),
            voltageVolts: ChartSeries(linePoints(rows.map { ($0.date, $0.voltageMV.map { $0 / 1000 }) })),
            chargeLimitPercent: ChartSeries(chargeLimitSteps(chargeLimitEvents, in: domain)),
            stats: stats
        )
    }

    /// 充电上限阶梯线的转折点：范围起点取起点之前最后一条事件的值，之后每条事件一个点，最后补到范围终点。
    /// 范围内外都没有事件时为空。
    static func chargeLimitSteps(_ events: [BatteryEvent], in domain: ClosedRange<Date>) -> [ChartPoint] {
        var points: [ChartPoint] = []
        if let initial = events.last(where: { $0.date <= domain.lowerBound })?.value {
            points.append(ChartPoint(date: domain.lowerBound, value: Double(initial)))
        }
        for event in events where event.date > domain.lowerBound && event.date <= domain.upperBound {
            guard let value = event.value else { continue }
            points.append(ChartPoint(date: event.date, value: Double(value)))
        }
        if let last = points.last, last.date < domain.upperBound {
            points.append(ChartPoint(date: domain.upperBound, value: last.value))
        }
        return points
    }

    /// 把 `[start, end)` 裁剪到范围内并合并重叠的区间；`end` 为 nil 表示进行中，画到范围终点。
    static func mergedRanges(_ spans: [(start: Date, end: Date?)], in domain: ClosedRange<Date>) -> [Range<Date>] {
        let clipped: [Range<Date>] = spans.compactMap { span in
            let lower = max(span.start, domain.lowerBound)
            let upper = min(span.end ?? domain.upperBound, domain.upperBound)
            return lower < upper ? lower..<upper : nil
        }
        var result: [Range<Date>] = []
        for range in clipped.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - 长期

    /// 全部每日数据，每天一个点，画在当天正午。横轴从最早记录当天 0 点到明天 0 点。
    static func longTerm(
        dailySamples: [DailyHealth],
        calibrationRuns: [CalibrationRun] = [],
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
        let fullCharge = linePoints(days.map { ($0.date, $0.sample.fullChargeCapacityMAh.map(Double.init)) })
        let cycles = linePoints(days.map { ($0.date, $0.sample.cycleCount.map(Double.init)) })
        return LongTermChartData(
            hoverPoints: days.map { ChartPoint(date: $0.date, value: 0) },
            domain: domain,
            maxGap: maxGap,
            notRecorded: notRecordedRange(in: domain, recordStart: firstRecordedStart),
            maximumCapacityPercent: ChartSeries(linePoints(days.map { ($0.date, $0.sample.systemMaxCapacityPercent.map(Double.init)) })),
            capacityRatioPercent: ChartSeries(linePoints(days.map { ($0.date, capacityRatioPercent($0.sample)) })),
            fullChargeCapacityMAh: ChartSeries(fullCharge),
            fullChargeTrend: ChartSeries(rollingAverage(fullCharge)),
            cycleCount: ChartSeries(cycles),
            calibrationDays: calibrationDays(calibrationRuns, in: domain, calendar: calendar),
            designCapacityMAh: days.last { $0.sample.designCapacityMAh != nil }?.sample.designCapacityMAh,
            trend: healthTrend(fullCharge: fullCharge, cycles: cycles),
            cyclesPerMonth: cyclesPerMonth(cycles)
        )
    }

    /// 完成的校准按结束当天去重，取当天正午。
    static func calibrationDays(_ runs: [CalibrationRun], in domain: ClosedRange<Date>, calendar: Calendar) -> [Date] {
        let days = Set(runs.compactMap { run -> Date? in
            guard run.result == .completed, let ended = run.endedAt else { return nil }
            return calendar.startOfDay(for: ended).addingTimeInterval(12 * 3600)
        })
        return days.filter { domain.contains($0) }.sorted()
    }

    static let trendWindow: TimeInterval = 14 * 86400
    static let trendMinimumPoints = 5
    static let comparisonWindow: TimeInterval = 30 * 86400
    static let averageMonth: TimeInterval = 30.44 * 86400

    /// 14 天滑动平均：每个点取它之前 14 天内（含当天）的读数，少于 5 个时不画。
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
                result.append(ChartPoint(date: point.date, value: sum / Double(count)))
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

    /// 按时间顺序生成曲线点。缺失值不生成点，前后的点直接相连。
    static func linePoints(_ values: [(date: Date, value: Double?)]) -> [ChartPoint] {
        values.compactMap { date, value in
            value.map { ChartPoint(date: date, value: $0) }
        }
    }

    /// 功率曲线：每个分钟样本取滑动平均作为读数，绘图只取抽稀后的点，让曲线更平滑。
    /// 先去掉短于 `powerMinimumRunSamples` 的片段；最后一段正在记录，不论长短都保留。
    static func powerSeries(_ points: [ChartPoint]) -> ChartSeries {
        let maxGap = sampleInterval * maxGapIntervals
        let segments = runs(points, maxGap: maxGap)
        let kept = segments.enumerated().flatMap { index, run in
            run.count >= powerMinimumRunSamples || index == segments.count - 1 ? run : []
        }
        let averaged = movingAverage(kept, window: powerAverageWindow)
        return ChartSeries(averaged, plotPoints: thinned(averaged, interval: powerPlotInterval, maxGap: maxGap))
    }

    /// 按缺口切段：相邻两点间隔超过 `maxGap` 时断开。`points` 按时间排序。
    static func runs(_ points: [ChartPoint], maxGap: TimeInterval) -> [[ChartPoint]] {
        var result: [[ChartPoint]] = []
        for point in points {
            if let last = result.last?.last, point.date.timeIntervalSince(last.date) <= maxGap {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }

    /// 抽稀：与上一个保留点相隔不少于 `interval` 的点才保留。首尾点和缺口（相邻间隔超过 `maxGap`）两侧的点
    /// 总是保留，跨缺口的连线仍从真实的首尾样本画起。`points` 按时间排序。
    static func thinned(_ points: [ChartPoint], interval: TimeInterval, maxGap: TimeInterval) -> [ChartPoint] {
        var result: [ChartPoint] = []
        for (index, point) in points.enumerated() {
            let isLast = index == points.count - 1
            let beforeGap = !isLast && points[index + 1].date.timeIntervalSince(point.date) > maxGap
            let afterGap = index > 0 && point.date.timeIntervalSince(points[index - 1].date) > maxGap
            guard let kept = result.last else {
                result.append(point)
                continue
            }
            if isLast || beforeGap || afterGap || point.date.timeIntervalSince(kept.date) >= interval {
                result.append(point)
            }
        }
        return result
    }

    /// 滑动平均：每个点取前后各 `window / 2` 内所有点的平均值，日期不变，所以读数和悬停仍对准采样时刻。
    /// 只用窗口内真实存在的点，缺口不补值；孤立的点保持原值。`points` 按时间排序。
    static func movingAverage(_ points: [ChartPoint], window: TimeInterval) -> [ChartPoint] {
        let half = window / 2
        var lower = 0
        var upper = 0
        return points.map { point in
            while point.date.timeIntervalSince(points[lower].date) > half { lower += 1 }
            while upper < points.count, points[upper].date.timeIntervalSince(point.date) <= half { upper += 1 }
            let values = points[lower..<upper].map(\.value)
            return ChartPoint(date: point.date, value: values.reduce(0, +) / Double(values.count))
        }
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
    /// 0 算作正。
    static func signedRuns(_ points: [ChartPoint]) -> [SignedRun] {
        var runs: [SignedRun] = []
        var current: SignedRun?
        for point in points {
            let isPositive = point.value >= 0
            guard var run = current, let last = run.points.last else {
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
                value: 0
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

    /// 按点数分桶，每桶保留首尾、最小及最大值，保持真实时间顺序。约不超过 targetCount 个绘图点。
    static func downsample(_ points: [ChartPoint], targetCount: Int = 1200) -> [ChartPoint] {
        guard points.count > targetCount, targetCount >= 4 else { return points }
        let bucketSize = Int(ceil(Double(points.count) / Double(targetCount / 4)))
        var result: [ChartPoint] = []
        for lower in stride(from: 0, to: points.count, by: bucketSize) {
            let upper = min(lower + bucketSize, points.count)
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
        return result
    }

    /// 悬停选中的采样点。首尾采样之间吸附到最近的采样，不限距离，缺口上也不插值；
    /// 首尾之外只取 `maxGap` 内的点，避免在“未记录”区间选中第一条记录。
    static func hoverPoint(in points: [ChartPoint], to date: Date, maxGap: TimeInterval) -> ChartPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        let isInsideRecords = date >= first.date && date <= last.date
        return nearest(in: points, to: date, within: isInsideRecords ? .infinity : maxGap)
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
