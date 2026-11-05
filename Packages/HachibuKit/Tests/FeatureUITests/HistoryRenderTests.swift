import AppKit
import BatteryCore
import HistoryStore
import SwiftUI
import Testing
@testable import FeatureUI

/// 检查历史图表、平滑曲线和跨缺口连线；仅设置 HACHIBU_RENDER_DIR 时出图。
@MainActor
@Suite struct HistoryRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderRecentAxisLabels() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // 末端离整点仅 9 分钟，复现日期标签紧贴右侧纵轴的情况。
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 15, minute: 9)))
        let start = end.addingTimeInterval(-48 * 3600)
        let dates = (0...48).map { start.addingTimeInterval(Double($0) * 3600) }
        let percent = ChartSeries(dates.map { ChartPoint(date: $0, value: 98) })
        let temperature = ChartSeries(dates.enumerated().map {
            ChartPoint(date: $0.element, value: 26 + 2 * sin(Double($0.offset)))
        })
        let variants: [(ColorScheme, String, String)] = [(.light, "zh-Hans", "light"), (.dark, "zh-Hans", "dark"), (.light, "en", "light-en")]
        for width in [672.0, 912.0] {
            for (scheme, locale, name) in variants {
                let charts = HStack(spacing: 18) {
                    MetricChartCard(
                        series: percent, domain: start...end, maxGap: 180,
                        yScale: .fixed(0...100), style: .line(.brand), height: 168, hoverDate: .constant(nil)
                    )
                    MetricChartCard(
                        series: temperature, threshold: 35, domain: start...end, maxGap: 180,
                        style: .line(.red), height: 168, hoverDate: .constant(nil)
                    )
                }
                let renderer = ImageRenderer(content: charts
                    .frame(width: width)
                    .padding(20)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.timeZone, timeZone))
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: directory.appendingPathComponent("history-recent-axis-\(Int(width))-\(name).png"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderHealthMetrics() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_792_454_400)
        let dates = (0..<10).map { start.addingTimeInterval(Double($0) * 86_400) }
        let capacity = ChartSeries(dates.enumerated().map {
            ChartPoint(date: $0.element, value: $0.offset < 5 ? 96 : 95)
        })
        let cycles = ChartSeries(dates.enumerated().map {
            ChartPoint(date: $0.element, value: $0.offset < 5 ? 34 : 35)
        })
        for scheme in [ColorScheme.light, .dark] {
            let charts = VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: "Maximum Capacity (System)")
                MetricChartCard(
                    series: capacity, domain: dates[0]...dates[9], maxGap: 3 * 86_400,
                    yScale: .minimumSpan(10, upperLimit: 100), style: .line(.brand), hoverDate: .constant(nil)
                )
                Text(verbatim: "Cycle Count")
                MetricChartCard(
                    series: cycles, domain: dates[0]...dates[9], maxGap: 3 * 86_400,
                    yScale: .automatic(includesZero: false), integerYTicks: true, style: .line(.brand), hoverDate: .constant(nil)
                )
            }
            let renderer = ImageRenderer(content: charts
                .padding(20)
                .frame(width: 700)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                .environment(\.colorScheme, scheme))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("history-health-metrics-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"] != nil))
    func renderMissingHoveredMetric() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HACHIBU_RENDER_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_792_454_400)
        let dates = (0..<5).map { start.addingTimeInterval(Double($0) * 60) }
        let percent = ChartSeries(dates.enumerated().map {
            ChartPoint(date: $0.element, value: Double(60 + $0.offset * 5))
        })
        let temperature = ChartSeries(HistoryChartBuilder.linePoints(dates.enumerated().map {
            ($0.element, $0.offset == 2 ? nil : Double(30 + $0.offset))
        }))
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
            ChartPoint(date: start.addingTimeInterval(Double($0) * 60), value: Double(60 + $0 * 5))
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
            // 留出 5 小时缺口，确认曲线连过去、插电底色仍然断开。
            guard !(900..<1200).contains(minute) else { continue }
            let phase = Double(minute) / 90
            let isExternal = (minute / 240) % 2 == 1
            // 中途改变充电上限，确认历史图不再显示上限线。
            try await store.record(
                BatterySnapshot(
                    percent: Int(65 + 15 * sin(phase)),
                    isExternalPower: isExternal,
                    isCharging: isExternal && sin(phase) < 0.5,
                    temperatureCelsius: 31 + 5 * sin(phase + 0.8),
                    chargeLimit: .on(percent: minute < 2000 ? 80 : 90)
                ),
                at: now.addingTimeInterval(Double(minute - 2879) * 60)
            )
        }
        // 400 天的每日数据，满充容量缓慢下降并带日常波动；中间缺 4 天。
        for day in 0..<400 {
            guard !(212..<216).contains(day) else { continue }
            let date = Calendar.current.date(byAdding: .day, value: day - 399, to: now)!
            let noise = Int(60 * sin(Double(day) * 1.7) + 35 * sin(Double(day) * 0.31))
            try await store.record(
                BatteryHealthInfo(systemMaximumCapacityPercent: day < 260 ? 96 : 95, condition: .good),
                snapshot: BatterySnapshot(
                    fullChargeCapacityMAh: 8090 - day * 4 / 10 + noise,
                    designCapacityMAh: 8694,
                    cycleCount: 34 + day * 34 / 400
                ),
                at: date
            )
        }
        let model = HistoryModel(store: store)
        await model.reloadAll()
        let variants: [(ColorScheme, String, String)] = [(.light, "zh-Hans", "light"), (.dark, "zh-Hans", "dark"), (.light, "en", "light-en")]
        for (scheme, locale, name) in variants {
            // 宽度按默认窗口 1200pt 减去侧栏。
            let renderer = ImageRenderer(content: HistoryChartsContent(model: model, temperatureThreshold: 40)
                .frame(width: 968)
                .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: locale)))
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("history-\(name).png"))
        }
    }
}
