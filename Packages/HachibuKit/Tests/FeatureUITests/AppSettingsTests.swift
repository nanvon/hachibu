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
            #expect(settings.menuBarIconStyle == .battery)
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
            settings.menuBarIconStyle = .battery
            settings.temperatureAlertEnabled = false
            settings.temperatureAlertThreshold = 45
            settings.healthAlertEnabled = false
            settings.healthAlertThreshold = 70

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarContent == .temperature)
            #expect(reloaded.menuBarIconStyle == .battery)
            #expect(!reloaded.temperatureAlertEnabled)
            #expect(reloaded.temperatureAlertThreshold == 45)
            #expect(!reloaded.healthAlertEnabled)
            #expect(reloaded.healthAlertThreshold == 70)
        }
    }

    @Test func invalidStoredValuesFallBack() {
        withDefaults { defaults in
            defaults.set("unknown", forKey: "menuBarContent")
            defaults.set("unknown", forKey: "menuBarIconStyle")
            defaults.set(200, forKey: "temperatureAlertThreshold")
            defaults.set(10, forKey: "healthAlertThreshold")

            let settings = AppSettings(defaults: defaults)
            #expect(settings.menuBarContent == .batteryLevel)
            #expect(settings.menuBarIconStyle == .battery)
            #expect(settings.temperatureAlertThreshold == AppSettings.temperatureThresholdRange.upperBound)
            #expect(settings.healthAlertThreshold == AppSettings.healthThresholdRange.lowerBound)
        }
    }

    @Test func existingReadingPreferenceSurvivesIconChanges() {
        withDefaults { defaults in
            // 旧版本只存显示内容；升级后默认 macOS 图标，原读数选择保留。
            defaults.set("systemPower", forKey: "menuBarContent")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.menuBarIconStyle == .battery)
            #expect(settings.menuBarContent == .systemPower)

            settings.menuBarIconStyle = .ios
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarIconStyle == .ios)
            #expect(reloaded.menuBarContent == .systemPower)
        }
    }

    @Test(arguments: ["brand", "batteryColored", "hidden", "unknown"])
    func removedStylesFallBackToMacOS(storedStyle: String) {
        withDefaults { defaults in
            defaults.set(storedStyle, forKey: "menuBarIconStyle")
            defaults.set("systemPower", forKey: "menuBarContent")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.menuBarIconStyle == .battery)
            #expect(settings.menuBarContent == .systemPower)
        }
    }

    @Test(arguments: [MenuBarIconStyle.battery, .ios])
    func iconStylesPreserveReadingPreference(style: MenuBarIconStyle) {
        withDefaults { defaults in
            defaults.set("temperature", forKey: "menuBarContent")
            let settings = AppSettings(defaults: defaults)
            settings.menuBarIconStyle = style

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarIconStyle == style)
            #expect(reloaded.menuBarContent == .temperature)
        }
    }
}
