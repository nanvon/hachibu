import Foundation
import Testing
@testable import FeatureUI

@MainActor
@Suite struct AppSettingsTests {
    /// 每个测试用独立的 UserDefaults 域，结束时删除。
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test func usesDefaultsWhenNothingStored() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            #expect(settings.menuBarContent == .batteryLevel)
            #expect(settings.temperatureAlertEnabled)
            #expect(settings.temperatureAlertThreshold == 40)
            #expect(settings.healthAlertEnabled)
            #expect(settings.healthAlertThreshold == 80)
        }
    }

    @Test func changesArePersisted() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.menuBarContent = .temperature
            settings.temperatureAlertEnabled = false
            settings.temperatureAlertThreshold = 45
            settings.healthAlertEnabled = false
            settings.healthAlertThreshold = 70

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarContent == .temperature)
            #expect(!reloaded.temperatureAlertEnabled)
            #expect(reloaded.temperatureAlertThreshold == 45)
            #expect(!reloaded.healthAlertEnabled)
            #expect(reloaded.healthAlertThreshold == 70)
        }
    }

    @Test func invalidStoredValuesFallBack() {
        withDefaults { defaults in
            defaults.set("unknown", forKey: "menuBarContent")
            defaults.set(200, forKey: "temperatureAlertThreshold")
            defaults.set(10, forKey: "healthAlertThreshold")

            let settings = AppSettings(defaults: defaults)
            #expect(settings.menuBarContent == .batteryLevel)
            #expect(settings.temperatureAlertThreshold == AppSettings.temperatureThresholdRange.upperBound)
            #expect(settings.healthAlertThreshold == AppSettings.healthThresholdRange.lowerBound)
        }
    }
}
