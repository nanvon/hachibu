import AppKit
import BatteryCore
import HistoryStore
import SwiftUI
import Testing
@testable import FeatureUI

/// 检查历史页保留的六张图、平滑曲线和数据缺口；仅设置 HACHIBU_RENDER_DIR 时出图。
@MainActor
@Suite struct HistoryRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderMissingHoveredMetric() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_792_454_400)
        let dates = (0..<5).map { start.addingTimeInterval(Double($0) * 60) }
        let percent = ChartSeries(dates.enumerated().map {
            ChartPoint(date: $0.element, value: Double(60 + $0.offset * 5), segment: 0)
        })
        let temperature = ChartSeries(HistoryChartBuilder.segmented(dates.enumerated().map {
            ($0.element, $0.offset == 2 ? nil : Double(30 + $0.offset))
        }, maxGap: 180))
        for scheme in [ColorScheme.light, .dark] {
            let charts = HStack(alignment: .top, spacing: 18) {
                MetricChart(
                    title: Text(verbatim: "Battery Level"), series: percent, hoverPoints: percent.points,
                    domain: dates[0]...dates[4], maxGap: 180, yScale: .fixed(0...100), style: .line(.blue),
                    formatValue: { "\(Int($0))%" },
                    formatDate: { $0.formatted(date: .omitted, time: .shortened) },
                    hoverDate: .constant(dates[2])
                )
                MetricChart(
                    title: Text(verbatim: "Battery Temperature"), series: temperature, hoverPoints: percent.points,
                    domain: dates[0]...dates[4], maxGap: 180, style: .line(.red),
                    formatValue: { DisplayFormat.celsius($0) },
                    formatDate: { $0.formatted(date: .omitted, time: .shortened) },
                    hoverDate: .constant(dates[2])
                )
            }
            let renderer = ImageRenderer(content: charts
                .padding(20)
                .frame(width: 940)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("history-hover-missing-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderHoveredChart() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_792_454_400)
        let points = (0..<5).map {
            ChartPoint(date: start.addingTimeInterval(Double($0) * 60), value: Double(60 + $0 * 5), segment: 0)
        }
        let series = ChartSeries(points)
        for scheme in [ColorScheme.light, .dark] {
            let chart = MetricChart(
                title: Text(verbatim: "Battery Level"), series: series, hoverPoints: points,
                domain: start...start.addingTimeInterval(240), maxGap: 180,
                yScale: .fixed(0...100), style: .line(.blue),
                formatValue: { "\(Int($0))%" },
                formatDate: { $0.formatted(date: .omitted, time: .shortened) },
                hoverDate: .constant(points[2].date)
            )
            let renderer = ImageRenderer(content: chart
                .padding(20)
                .frame(width: 480)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("history-hover-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderHistory() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try HistoryStore.inMemory()
        let now = Date()
        for minute in 0..<2880 {
            // 留出半小时缺口，确认平滑后仍然断开。
            guard !(900..<930).contains(minute) else { continue }
            let phase = Double(minute) / 90
            try await store.write(MinuteSample(
                timestamp: now.addingTimeInterval(Double(minute - 2879) * 60),
                percent: Int(65 + 15 * sin(phase)),
                isExternalPower: (minute / 240) % 2 == 1,
                temperatureCelsius: 30 + 4 * sin(phase + 0.8)
            ))
        }
        for day in 0..<25 {
            guard !(12..<16).contains(day) else { continue }
            let date = Calendar.current.date(byAdding: .day, value: day - 24, to: now)!
            try await store.record(
                BatteryHealthInfo(systemMaximumCapacityPercent: day < 18 ? 96 : 95, condition: .good),
                snapshot: BatterySnapshot(
                    fullChargeCapacityMAh: 8050 - day * 3 + (day % 4) * 5,
                    designCapacityMAh: 8694,
                    cycleCount: 28 + day / 3
                ),
                at: date
            )
        }
        let model = HistoryModel(store: store)
        await model.reloadAll()
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: HistoryChartsContent(model: model)
                .frame(width: 1040, height: 1180)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "zh-Hans")))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("history-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
