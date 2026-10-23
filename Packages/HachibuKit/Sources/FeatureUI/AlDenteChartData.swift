import Foundation
import HistoryStore

enum AlDenteChartRange: CaseIterable, Sendable {
    case day, week, month, year, all

    var duration: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .year: 365 * 86_400
        case .all: nil
        }
    }
}

enum AlDenteHistoryPresentation: CaseIterable {
    case chart, records
}

extension AlDenteTable {
    var supportsChart: Bool {
        switch self {
        case .batterySerial, .macOSbatteryCondition, .lastCalibration: false
        default: true
        }
    }

    /// 沿用三周期断线原则；设计容量没有固定周期，只展示独立点。
    var chartMaxGap: TimeInterval {
        switch self {
        case .batteryCycles, .batteryMaxCap, .macOSbatteryMaxCap: 3 * 86_400
        case .batteryDesignCap: 0
        default: 180
        }
    }

    var isUnverifiedPower: Bool {
        self == .chargingPower || self == .systemLoad || self == .systemPowerIn
    }
}

struct AlDenteChartPoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let value: Double
    let sourceValue: String
    let segment: Int
}

struct AlDenteChartData: Sendable {
    let points: [AlDenteChartPoint]
    /// 悬停查询使用范围内全部原始点，不能用精简后的绘图点代替最近观测值。
    let sourcePoints: [AlDenteChartPoint]
    let domain: ClosedRange<Date>?
    let sourcePointCount: Int
    let invalidTimestampCount: Int
    let unplottableValueCount: Int
    let duplicateTimestampCount: Int

    func nearest(to date: Date, within maxDistance: TimeInterval) -> AlDenteChartPoint? {
        var low = 0
        var high = sourcePoints.count
        while low < high {
            let mid = (low + high) / 2
            if sourcePoints[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let closest = [low - 1, low].filter { sourcePoints.indices.contains($0) }.map { sourcePoints[$0] }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        guard let closest, abs(closest.date.timeIntervalSince(date)) <= maxDistance else { return nil }
        return closest
    }
}

/// 时间和值的转换仅用于展示；来源表及原始 JSON 保持不变。
struct AlDenteChartSeries: Sendable {
    let points: [AlDenteChartPoint]
    let invalidTimestampCount: Int
    let unplottableValueCount: Int
    let duplicateTimestampCount: Int

    init(records: [AlDenteHistoryRecord], table: AlDenteTable) {
        let formatter = Self.timestampFormatter()
        var invalidTime = 0
        var invalidValue = 0
        var values: [(record: AlDenteHistoryRecord, date: Date, value: Double)] = []
        for record in records {
            guard let date = formatter.date(from: record.timestamp),
                  formatter.string(from: date) == record.timestamp else {
                invalidTime += 1
                continue
            }
            let value: Double?
            switch record.value {
            case .integer(let integer): value = Double(exactly: integer)
            case .real(let real): value = real.isFinite ? real : nil
            case .text: value = nil
            }
            guard let value else {
                invalidValue += 1
                continue
            }
            values.append((record, date, value))
        }
        values.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.record.sourceID != $1.record.sourceID { return $0.record.sourceID < $1.record.sourceID }
            return $0.record.id < $1.record.id
        }
        var points: [AlDenteChartPoint] = []
        var segment = 0
        var previousDate: Date?
        var duplicates = 0
        for index in values.indices {
            let value = values[index]
            let duplicate = (index > 0 && values[index - 1].date == value.date)
                || (index + 1 < values.count && values[index + 1].date == value.date)
            // 同时刻多条记录各自画点，避免用连线选择其中一个值或伪造先后关系。
            if duplicate || previousDate.map({ value.date.timeIntervalSince($0) > table.chartMaxGap }) == true {
                segment += 1
            }
            points.append(AlDenteChartPoint(id: value.record.id, date: value.date, value: value.value,
                sourceValue: value.record.value.sourceDescription, segment: segment))
            if duplicate {
                duplicates += 1
                segment += 1
                previousDate = nil
            } else {
                previousDate = value.date
            }
        }
        self.points = points
        invalidTimestampCount = invalidTime
        unplottableValueCount = invalidValue
        duplicateTimestampCount = duplicates
    }

    func chart(range: AlDenteChartRange) -> AlDenteChartData {
        guard let first = points.first?.date, let last = points.last?.date else {
            return AlDenteChartData(points: [], sourcePoints: [], domain: nil, sourcePointCount: 0,
                invalidTimestampCount: invalidTimestampCount, unplottableValueCount: unplottableValueCount,
                duplicateTimestampCount: duplicateTimestampCount)
        }
        let start = range.duration.map { last.addingTimeInterval(-$0) } ?? first
        let domain = start < last ? start...last : last.addingTimeInterval(-1800)...last.addingTimeInterval(1800)
        let visible = points.filter { domain.contains($0.date) }
        return AlDenteChartData(points: Self.reduced(visible, domain: domain), sourcePoints: visible, domain: domain,
            sourcePointCount: visible.count, invalidTimestampCount: invalidTimestampCount,
            unplottableValueCount: unplottableValueCount, duplicateTimestampCount: duplicateTimestampCount)
    }

    /// 每段、每个时间桶保留首末和极值；仅减少绘图点，不跨缺口连线、不修改来源数据。
    private static func reduced(_ points: [AlDenteChartPoint], domain: ClosedRange<Date>) -> [AlDenteChartPoint] {
        guard points.count > 2000 else { return points }
        let width = domain.upperBound.timeIntervalSince(domain.lowerBound) / 500
        var output: [AlDenteChartPoint] = []
        var group: [AlDenteChartPoint] = []
        var previousBucket: Int?
        func flush() {
            guard !group.isEmpty else { return }
            let minimum = group.indices.min { group[$0].value < group[$1].value }!
            let maximum = group.indices.max { group[$0].value < group[$1].value }!
            for index in Set([0, group.count - 1, minimum, maximum]).sorted() { output.append(group[index]) }
            group.removeAll(keepingCapacity: true)
        }
        for point in points {
            let bucket = Int(point.date.timeIntervalSince(domain.lowerBound) / width)
            if previousBucket != bucket || group.last.map({ $0.segment != point.segment }) == true { flush() }
            group.append(point)
            previousBucket = bucket
        }
        flush()
        return output
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.isLenient = false
        return formatter
    }
}
