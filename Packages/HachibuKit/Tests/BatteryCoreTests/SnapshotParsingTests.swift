import Foundation
import Testing
@testable import BatteryCore

@Suite struct SnapshotParsingTests {
    @Test func noInternalBattery() {
        let empty = RawBatteryReadings(
            powerSources: [],
            smartBattery: nil,
            smartBatteryPack: nil,
            adapterDetails: nil,
            chargeLimitArchive: nil,
            lowPowerModeEnabled: false
        )
        #expect(BatteryReading(empty) == .noBattery)

        var ups = empty
        ups.powerSources = [["Type": .string("UPS"), "Current Capacity": .int(50)]]
        #expect(BatteryReading(ups) == .noBattery)
    }

    @Test(arguments: [
        (RawValue.int(0), Int?.none),
        (.int(-1), nil),
        (.int(65535), nil),
        (.int(70000), nil),
        (.int(125), 125),
        (.string("125"), nil),
    ])
    func timeRemainingSentinels(_ raw: RawValue, _ expected: Int?) {
        let snapshot = BatteryReading(.battery(["Time to Empty": raw, "Time to Full Charge": raw])).snapshot
        #expect(snapshot?.timeToEmptyMinutes == expected)
        #expect(snapshot?.timeToFullMinutes == expected)
    }

    @Test func percentUsesMaxCapacity() {
        let half = BatteryReading(.battery(["Current Capacity": .int(4000), "Max Capacity": .int(8000)])).snapshot
        #expect(half?.percent == 50)

        let zeroMax = BatteryReading(.battery(["Current Capacity": .int(80), "Max Capacity": .int(0)])).snapshot
        #expect(zeroMax?.percent == nil)
    }

    @Test func missingRegistryLeavesFieldsNil() throws {
        let snapshot = try #require(BatteryReading(.battery([
            "Current Capacity": .int(80),
            "Max Capacity": .int(100),
            "Power Source State": .string("Battery Power"),
            "Is Charging": .bool(false),
        ])).snapshot)

        #expect(snapshot.percent == 80)
        #expect(snapshot.isExternalPower == false)
        #expect(snapshot.isCharging == false)
        #expect(snapshot.voltageMV == nil)
        #expect(snapshot.systemLoadMW == nil)
        #expect(snapshot.temperatureCelsius == nil)
        #expect(snapshot.cycleCount == nil)
        #expect(snapshot.capacityRatio == nil)
        #expect(snapshot.adapter == nil)
        #expect(snapshot.chargeLimitPercent == nil)
    }

    @Test func wrongTypesReadAsNil() throws {
        let snapshot = try #require(BatteryReading(.battery(
            ["Is Charging": .int(1), "Power Source State": .int(1)],
            smartBattery: [
                "Voltage": .string("12241"),
                "UpdateTime": .int(0),
                "PowerTelemetryData": .array([]),
                "BatteryData": .dictionary(["FullChargeCapacity": .real(7942)]),
            ],
            smartBatteryPack: ["BatteryData": .dictionary(["Temperature": .string("2700")])]
        )).snapshot)

        #expect(snapshot.isCharging == nil)
        #expect(snapshot.isExternalPower == nil)
        #expect(snapshot.voltageMV == nil)
        #expect(snapshot.telemetryUpdatedAt == nil)
        #expect(snapshot.systemLoadMW == nil)
        #expect(snapshot.fullChargeCapacityMAh == nil)
        #expect(snapshot.temperatureCelsius == nil)
    }

    @Test func temperatureIsHundredthsOfDegree() {
        let snapshot = BatteryReading(.battery(
            [:],
            smartBatteryPack: ["BatteryData": .dictionary(["Temperature": .int(2669)])]
        )).snapshot
        #expect(snapshot?.temperatureCelsius == 26.69)
    }

    @Test func serialIsHashed() {
        // SHA-256("ABC")
        let expected = "b5d4045c3f466fa91fe2cc6abe79232a1a57cdf104f7a26e716e0a1e2789df78"
        let topLevel = BatteryReading(.battery([:], smartBattery: ["Serial": .string(" ABC\n")])).snapshot
        #expect(topLevel?.batterySerialHash == expected)

        let fromBatteryData = BatteryReading(.battery(
            [:],
            smartBattery: ["BatteryData": .dictionary(["Serial": .string("ABC")])]
        )).snapshot
        #expect(fromBatteryData?.batterySerialHash == expected)

        let empty = BatteryReading(.battery([:], smartBattery: ["Serial": .string("  ")])).snapshot
        #expect(empty?.batterySerialHash == nil)
        #expect(BatterySnapshot.serialHash("ABC") == expected)
    }

    @Test func healthConditionRawValue() {
        #expect(BatteryHealthCondition.good.rawValue == "Good")
        #expect(BatteryHealthCondition.other("Service Recommended").rawValue == "Service Recommended")
    }

    @Test func healthInfo() {
        func profiler(_ maximumCapacity: RawValue, _ condition: String) -> RawValue {
            .dictionary(["SPPowerDataType": .array([
                .dictionary(["_name": .string("sppower_information")]),
                .dictionary([
                    "_name": .string("spbattery_information"),
                    "sppower_battery_health_info": .dictionary([
                        "sppower_battery_health_maximum_capacity": maximumCapacity,
                        "sppower_battery_health": .string(condition),
                    ]),
                ]),
            ])])
        }

        let serviceRecommended = BatteryHealthInfo(systemProfilerPower: profiler(.string("79%"), "Service Recommended"))
        #expect(serviceRecommended == BatteryHealthInfo(
            systemMaximumCapacityPercent: 79,
            condition: .other("Service Recommended")
        ))
        #expect(BatteryHealthInfo(systemProfilerPower: profiler(.int(95), "Good")).systemMaximumCapacityPercent == nil)
        #expect(BatteryHealthInfo(systemProfilerPower: profiler(.string("abc"), "Good")).systemMaximumCapacityPercent == nil)
        #expect(BatteryHealthInfo(systemProfilerPower: nil) == BatteryHealthInfo(
            systemMaximumCapacityPercent: nil,
            condition: nil
        ))
    }
}
