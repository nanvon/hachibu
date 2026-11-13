import BatteryCore
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
            #expect(settings.menuBarContents == [.batteryLevel])
            #expect(settings.menuBarIconStyle == .battery)
            #expect(settings.temperatureAlertEnabled)
            #expect(settings.temperatureAlertThreshold == 40)
            #expect(settings.healthAlertEnabled)
            #expect(settings.healthAlertThreshold == 80)
            #expect(!settings.chargeCompleteAlertEnabled)
            #expect(!settings.lowBatteryAlertEnabled)
            #expect(settings.lowBatteryAlertThreshold == 20)
        }
    }

    @Test func changesArePersisted() {
        withDefaults { defaults in
            let settings = AppSettings(defaults: defaults)
            settings.menuBarContents = [.temperature]
            settings.menuBarIconStyle = .battery
            settings.temperatureAlertEnabled = false
            settings.temperatureAlertThreshold = 45
            settings.healthAlertEnabled = false
            settings.healthAlertThreshold = 70

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarContents == [.temperature])
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
            #expect(settings.menuBarContents == [.batteryLevel])
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
            #expect(settings.menuBarContents == [.systemPower])

            settings.menuBarIconStyle = .ios
            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarIconStyle == .ios)
            #expect(reloaded.menuBarContents == [.systemPower])
        }
    }

    @Test(arguments: ["brand", "batteryColored", "hidden", "unknown"])
    func removedStylesFallBackToMacOS(storedStyle: String) {
        withDefaults { defaults in
            defaults.set(storedStyle, forKey: "menuBarIconStyle")
            defaults.set("systemPower", forKey: "menuBarContent")
            let settings = AppSettings(defaults: defaults)
            #expect(settings.menuBarIconStyle == .battery)
            #expect(settings.menuBarContents == [.systemPower])
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
            #expect(reloaded.menuBarContents == [.temperature])
        }
    }
    @Test func multipleMenuBarContentsKeepFixedOrderAndWriteLegacyKey() {
        withDefaults { defaults in
            defaults.set("systemPower", forKey: "menuBarContent")
            let settings = AppSettings(defaults: defaults)
            settings.menuBarContents = [.temperature, .batteryLevel, .temperature]

            let reloaded = AppSettings(defaults: defaults)
            #expect(reloaded.menuBarContents == [.batteryLevel, .temperature])
            #expect(defaults.string(forKey: "menuBarContent") == "batteryLevel")

            settings.menuBarContents = []
            #expect(AppSettings(defaults: defaults).menuBarContents.isEmpty)
            // 都不选时旧键保留上一次的值。
            #expect(defaults.string(forKey: "menuBarContent") == "batteryLevel")
        }
    }

    @Test func unknownStoredContentsAreDropped() {
        withDefaults { defaults in
            defaults.set(["temperature", "unknown"], forKey: "menuBarContents")
            #expect(AppSettings(defaults: defaults).menuBarContents == [.temperature])
        }
    }

    @Test func menuBarTitleJoinsReadings() {
        let reading = BatteryReading.battery(BatterySnapshot(percent: 80, systemLoadMW: 12_300, temperatureCelsius: 31.2))
        let all = MenuBarTitle.string(for: reading, contents: [.batteryLevel, .systemPower, .temperature])
        #expect(all == [
            DisplayFormat.percent(80), DisplayFormat.watts(milliwatts: 12_300), DisplayFormat.celsius(31.2),
        ].joined(separator: "  "))
        #expect(MenuBarTitle.string(for: nil, contents: [.batteryLevel, .temperature]) == DisplayFormat.missing)
        #expect(MenuBarTitle.string(for: reading, contents: [.temperature], separator: ", ") == DisplayFormat.celsius(31.2))
    }
}
