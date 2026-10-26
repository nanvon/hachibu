import BatteryCore
import Foundation
import HistoryStore
import Testing
@testable import FeatureUI

/// 2026-10-20 00:00:00 UTC。
private let base = Date(timeIntervalSince1970: 1_792_454_400)

private func minute(_ offset: Int) -> Date {
    base.addingTimeInterval(TimeInterval(offset * 60))
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

@Suite struct SegmentTests {
    @Test func gapLongerThanMaxGapStartsNewSegment() {
        let points = HistoryChartBuilder.segmented(
            [(minute(0), 1), (minute(1), 2), (minute(4), 3), (minute(8), 4)],
            maxGap: 180
        )
        // 间隔 3 分钟仍然相连，4 分钟断开。
        #expect(points.map(\.segment) == [0, 0, 0, 1])
    }

    @Test func missingValueBreaksLineOnce() {
        let points = HistoryChartBuilder.segmented(
            [(minute(0), nil), (minute(1), 1), (minute(2), nil), (minute(3), nil), (minute(4), 2)],
            maxGap: 180
        )
        #expect(points.map(\.date) == [minute(1), minute(4)])
        #expect(points.map(\.segment) == [0, 1])
    }
}

@Suite struct IntervalTests {
    @Test func consecutiveSamplesMergeAndClampToEnd() {
        let intervals = HistoryChartBuilder.intervals(
            [(minute(0), true), (minute(1), true), (minute(2), false), (minute(3), true), (minute(5), true)],
            sampleInterval: 60,
            maxGap: 180,
            end: minute(5).addingTimeInterval(30)
        )
        #expect(intervals == [
            minute(0)..<minute(2),
            minute(3)..<minute(5).addingTimeInterval(30),
        ])
    }

    @Test func gapSplitsRun() {
        let intervals = HistoryChartBuilder.intervals(
            [(minute(0), true), (minute(10), true)],
            sampleInterval: 60,
            maxGap: 180,
            end: minute(20)
        )
        #expect(intervals == [minute(0)..<minute(1), minute(10)..<minute(11)])
    }
}

@Suite struct RecentTests {
    @Test func minuteSamplesInsideDomain() {
        let now = minute(48 * 60).addingTimeInterval(20)
        let samples = [
            MinuteSample(timestamp: minute(0), percent: 50, isExternalPower: true),
            MinuteSample(timestamp: minute(1), percent: 51, isExternalPower: true, systemLoadMW: 12_500),
            MinuteSample(timestamp: minute(2), percent: 52, isExternalPower: false, temperatureCelsius: 30.5),
        ]
        let data = HistoryChartBuilder.recent(minuteSamples: samples, now: now, firstRecordedAt: minute(0))

        #expect(data.domain == now.addingTimeInterval(-48 * 3600)...now)
        // minute(0) 早于范围起点。
        #expect(data.percent.points.map(\.value) == [51, 52])
        #expect(data.systemPowerWatts.points.map(\.value) == [12.5])
        #expect(data.temperatureCelsius.points.map(\.value) == [30.5])
        #expect(data.pluggedIn == [minute(1)..<minute(2)])
        #expect(data.maxGap == 180)
        #expect(data.notRecorded == nil)
        // 各指标共用全部采样时间，温度缺失时也能悬停并联动电量图。
        #expect(data.hoverPoints.map(\.date) == [minute(1), minute(2)])
    }

    @Test func notRecordedBeforeFirstSample() {
        let now = minute(48 * 60)
        let data = HistoryChartBuilder.recent(minuteSamples: [], now: now, firstRecordedAt: minute(45))
        #expect(data.notRecorded == minute(0)..<minute(45))

        let noRecord = HistoryChartBuilder.recent(minuteSamples: [], now: now, firstRecordedAt: nil)
        #expect(noRecord.notRecorded == nil)
    }
}

@Suite struct LongTermTests {
    private let now = base.addingTimeInterval(15 * 3600) // 2026-10-20 15:00 UTC

    private func daily(_ day: String, capacity: Int? = 95, cycles: Int? = 100) -> DailyHealth {
        DailyHealth(day: day, systemMaxCapacityPercent: capacity, fullChargeCapacityMAh: 6000, cycleCount: cycles)
    }

    @Test func allDailySamplesUseFullDomain() {
        let data = HistoryChartBuilder.longTerm(
            dailySamples: [daily("2026-10-18"), daily("2026-10-20", cycles: 101)],
            now: now,
            firstRecordedDay: "2026-10-18",
            calendar: utc
        )
        let start = base.addingTimeInterval(-2 * 24 * 3600)
        let end = base.addingTimeInterval(24 * 3600)
        let firstRecorded = base.addingTimeInterval(-2 * 24 * 3600)

        #expect(data.domain == start...end)
        #expect(data.notRecorded == nil)
        // 每天一个点，在当天正午。
        #expect(data.cycleCount.points.map(\.date) == [firstRecorded.addingTimeInterval(12 * 3600), base.addingTimeInterval(12 * 3600)])
        #expect(data.cycleCount.points.map(\.segment) == [0, 0])
    }

    @Test func allStartsAtFirstRecordWithoutNotRecorded() {
        let data = HistoryChartBuilder.longTerm(
            dailySamples: [daily("2026-10-18")],
            now: now,
            firstRecordedDay: "2026-10-18",
            calendar: utc
        )
        #expect(data.domain.lowerBound == base.addingTimeInterval(-2 * 24 * 3600))
        #expect(data.notRecorded == nil)
    }

    @Test func gapLongerThanThreeDaysBreaksLine() {
        let data = HistoryChartBuilder.longTerm(
            dailySamples: [daily("2026-10-10"), daily("2026-10-13"), daily("2026-10-17"), daily("2026-10-18", capacity: nil)],
            now: now,
            firstRecordedDay: "2026-10-10",
            calendar: utc
        )
        #expect(data.maximumCapacityPercent.points.map(\.segment) == [0, 0, 1])
    }

    @Test func capacityRatioNeedsBothCapacities() {
        let data = HistoryChartBuilder.longTerm(
            dailySamples: [
                DailyHealth(day: "2026-10-19", fullChargeCapacityMAh: 7942, designCapacityMAh: 8694),
                DailyHealth(day: "2026-10-20", fullChargeCapacityMAh: 7900),
            ],
            now: now,
            firstRecordedDay: "2026-10-19",
            calendar: utc
        )
        #expect(data.capacityRatioPercent.points.count == 1)
        #expect(abs((data.capacityRatioPercent.points.first?.value ?? 0) - 7942.0 / 8694 * 100) < 1e-9)
    }

    @Test func emptyHistoryShowsToday() {
        let data = HistoryChartBuilder.longTerm(dailySamples: [], now: now, firstRecordedDay: nil, calendar: utc)
        #expect(data.domain == base...base.addingTimeInterval(24 * 3600))
        #expect(data.maximumCapacityPercent.points.isEmpty)
    }

}

@Suite struct SignedRunTests {
    @Test func splitsAtZeroCrossingWithInterpolatedPoint() {
        let points = [
            ChartPoint(date: minute(0), value: 2, segment: 0),
            ChartPoint(date: minute(2), value: -6, segment: 0),
            ChartPoint(date: minute(3), value: -1, segment: 0),
            ChartPoint(date: minute(10), value: -3, segment: 1),
        ]
        let runs = HistoryChartBuilder.signedRuns(points)
        let crossing = ChartPoint(date: minute(0).addingTimeInterval(30), value: 0, segment: 0)

        #expect(runs.map(\.isPositive) == [true, false, false])
        #expect(runs[0].points == [points[0], crossing])
        #expect(runs[1].points == [crossing, points[1], points[2]])
        // 原来的断开处不补点。
        #expect(runs[2].points == [points[3]])
    }
}

@Suite struct NearestTests {
    private let points = [0, 10, 20].map { ChartPoint(date: minute($0), value: Double($0), segment: 0) }

    @Test func picksClosestPoint() {
        #expect(HistoryChartBuilder.nearest(in: points, to: minute(4), within: 600)?.value == 0)
        #expect(HistoryChartBuilder.nearest(in: points, to: minute(6), within: 600)?.value == 10)
        #expect(HistoryChartBuilder.nearest(in: points, to: minute(25), within: 600)?.value == 20)
    }

    @Test func nilWhenTooFar() {
        #expect(HistoryChartBuilder.nearest(in: points, to: minute(35), within: 600) == nil)
        #expect(HistoryChartBuilder.nearest(in: [], to: minute(0), within: 600) == nil)
    }
}

@Suite struct DownsampleTests {
    @Test func retainsSpikesEndpointsAndOriginalHoverValues() {
        let points = (0..<2880).map {
            ChartPoint(date: minute($0), value: $0 == 1501 ? 100 : $0 == 1502 ? -20 : 50, segment: 0)
        }
        let series = ChartSeries(points)
        #expect(series.plotPoints.count <= 1200)
        #expect(series.plotPoints.first == points.first)
        #expect(series.plotPoints.last == points.last)
        #expect(series.plotPoints.contains(points[1501]))
        #expect(series.plotPoints.contains(points[1502]))
        #expect(series.points == points)
        #expect(HistoryChartBuilder.nearest(in: series.points, to: minute(1503), within: 180) == points[1503])
        #expect(series.plotPoints.map(\.date) == series.plotPoints.map(\.date).sorted())
    }

    @Test func preservesBothSidesOfGapsAndMissingValues() {
        var values: [(date: Date, value: Double?)] = (0..<10_000).map { (minute($0), Double($0)) }
        values[1251].value = nil
        values.removeSubrange(5000..<5100)
        let points = HistoryChartBuilder.segmented(values, maxGap: 180)
        let plot = HistoryChartBuilder.downsample(points)
        #expect(plot.map(\.segment).contains(2))
        for offset in [0, 1250, 1252, 4999, 5100, 9999] {
            #expect(plot.contains { $0.date == minute(offset) })
        }
    }
}

@MainActor
@Suite struct HistoryModelTests {
    @Test func fixedRangesAndDailyUpdates() async throws {
        let store = try HistoryStore.inMemory()
        let now = Date()
        try await store.write(MinuteSample(timestamp: now.addingTimeInterval(-49 * 3600), percent: 10))
        try await store.write(MinuteSample(timestamp: now.addingTimeInterval(-47 * 3600), percent: 70))
        let oldDate = Calendar.current.date(byAdding: .year, value: -2, to: now)!
        try await store.record(BatterySnapshot(fullChargeCapacityMAh: 8000, cycleCount: 10), at: oldDate)
        let model = HistoryModel(store: store)
        await model.reloadAll()
        let recent = try #require(model.recent)
        #expect(recent.domain.upperBound.timeIntervalSince(recent.domain.lowerBound) == 48 * 3600)
        #expect(recent.percent.points.map(\.value) == [70])
        #expect(model.longTerm?.cycleCount.points.map(\.value) == [10])
        let previous = model.longTerm
        await model.reloadAll()
        #expect(model.longTerm == previous)
        // 即使最新分钟时间不变，当天健康值变化也必须刷新长期曲线。
        try await store.record(
            BatteryHealthInfo(systemMaximumCapacityPercent: 95, condition: .good),
            snapshot: BatterySnapshot(fullChargeCapacityMAh: 7900, cycleCount: 100),
            at: now
        )
        await model.reloadAll()
        #expect(model.longTerm?.cycleCount.points.map(\.value) == [10, 100])
    }
}
