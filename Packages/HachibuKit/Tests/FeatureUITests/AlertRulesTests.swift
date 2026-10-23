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
}

@Suite struct HealthAlertRuleTests {
    @Test func alertsOnceBelowThreshold() {
        var rule = HealthAlertRule()
        let results = [80, 79, 78].map { rule.update(maximumCapacity: $0, threshold: 80) }
        #expect(results == [false, true, false])
        #expect(rule.hasAlerted(threshold: 80))
    }

    @Test func missingCapacityDoesNotAlert() {
        var rule = HealthAlertRule()
        let alerted = rule.update(maximumCapacity: nil, threshold: 80)
        #expect(!alerted)
        #expect(rule.alertedThreshold == nil)
    }

    @Test func changedThresholdAllowsAnotherAlert() {
        var rule = HealthAlertRule(alertedThreshold: 80)
        let sameThreshold = rule.update(maximumCapacity: 79, threshold: 80)
        let newThreshold = rule.update(maximumCapacity: 79, threshold: 85)
        #expect(!sameThreshold)
        #expect(newThreshold)
        #expect(rule.alertedThreshold == 85)
    }
}
