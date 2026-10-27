import Foundation
import Testing
@testable import FeatureUI

/// `#expect` 里不能调用 mutating 方法，先把结果存到局部常量再断言。
@Suite struct TemperatureAlertRuleTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// 从 start 起每 `step` 秒一个读数，返回每次是否提醒。
    private func feed(_ rule: inout TemperatureAlertRule, _ temperatures: [Double?], step: TimeInterval = 60, threshold: Int = 40) -> [Bool] {
        temperatures.enumerated().map { index, temperature in
            rule.update(temperature: temperature, threshold: threshold, at: start.addingTimeInterval(Double(index) * step))
        }
    }

    @Test func alertsOnceAfterThreeMinutesAboveThreshold() {
        var rule = TemperatureAlertRule()
        let results = feed(&rule, [41, 41, 41, 41, 41, 41])
        #expect(results == [false, false, false, true, false, false])
        #expect(rule.hasAlerted)
    }

    @Test func atThresholdDoesNotCount() {
        var rule = TemperatureAlertRule()
        let results = feed(&rule, [40, 40, 40, 40, 40])
        #expect(!results.contains(true))
    }

    @Test func dipBelowThresholdRestartsTiming() {
        var rule = TemperatureAlertRule()
        let results = feed(&rule, [41, 41, 41, 39, 41, 41, 41, 41])
        #expect(results == [false, false, false, false, false, false, false, true])
    }

    @Test func missingReadingRestartsTiming() {
        var rule = TemperatureAlertRule()
        let threeMinutesAfterGap = feed(&rule, [41, 41, 41, nil, 41, 41, 41, 41])
        #expect(threeMinutesAfterGap.last == true)

        var other = TemperatureAlertRule()
        let twoMinutesAfterGap = feed(&other, [41, 41, 41, nil, 41, 41, 41])
        #expect(!twoMinutesAfterGap.contains(true))
    }

    @Test func longGapRestartsTiming() {
        var rule = TemperatureAlertRule()
        let results = [0, 3600, 3660].map {
            rule.update(temperature: 41, threshold: 40, at: start.addingTimeInterval($0))
        }
        #expect(!results.contains(true))
    }

    @Test func recoversAfterFiveMinutesBelowMargin() {
        // 39 °C 没有低于 40 − 2，不算恢复。
        var notLowEnough = TemperatureAlertRule(hasAlerted: true)
        _ = feed(&notLowEnough, [39, 39, 39, 39, 39, 39, 39])
        #expect(notLowEnough.hasAlerted)

        var fourMinutes = TemperatureAlertRule(hasAlerted: true)
        _ = feed(&fourMinutes, [37, 37, 37, 37, 37])
        #expect(fourMinutes.hasAlerted)

        var fiveMinutes = TemperatureAlertRule(hasAlerted: true)
        _ = feed(&fiveMinutes, [37, 37, 37, 37, 37, 37])
        #expect(!fiveMinutes.hasAlerted)
    }

    @Test func missingReadingDoesNotCountAsRecovery() {
        var rule = TemperatureAlertRule(hasAlerted: true)
        _ = feed(&rule, [37, 37, 37, nil, 37, 37, 37])
        #expect(rule.hasAlerted)
    }

    @Test func alertsAgainAfterRecovery() {
        var rule = TemperatureAlertRule()
        let results = feed(&rule, [41, 41, 41, 41] + Array(repeating: 37, count: 6) + [41, 41, 41, 41])
        #expect(results.filter { $0 }.count == 2)
        #expect(results.last == true)
    }

    @Test func changingThresholdRestartsHighTemperatureTiming() {
        var rule = TemperatureAlertRule()
        _ = feed(&rule, [41, 41, 41])
        let firstHotReading = rule.update(temperature: 46, threshold: 45, at: start.addingTimeInterval(180))
        #expect(!firstHotReading)
        let results = [240.0, 300, 360].map {
            rule.update(temperature: 46, threshold: 45, at: start.addingTimeInterval($0))
        }
        #expect(results == [false, false, true])
    }

    @Test func changingThresholdRestartsRecoveryTiming() {
        var rule = TemperatureAlertRule(hasAlerted: true)
        _ = feed(&rule, [37, 37, 37, 37, 37])
        // 37°C 在新阈值 35°C 下已经不属于恢复区间。
        _ = rule.update(temperature: 32, threshold: 35, at: start.addingTimeInterval(300))
        #expect(rule.hasAlerted)
        for second in [360.0, 420, 480, 540] {
            _ = rule.update(temperature: 32, threshold: 35, at: start.addingTimeInterval(second))
        }
        #expect(rule.hasAlerted)
        _ = rule.update(temperature: 32, threshold: 35, at: start.addingTimeInterval(600))
        #expect(!rule.hasAlerted)
    }
}
