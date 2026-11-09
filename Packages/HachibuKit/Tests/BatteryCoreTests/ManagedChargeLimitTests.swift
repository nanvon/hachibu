import Foundation
import Testing
@testable import BatteryCore

@Suite struct ManagedChargeLimitTests {
    @Test func calibrationThenHoldThenTargetAndHelperFallback() {
        let hold = ChargeLimitHold(userLimit: 60, heldLimit: 75)
        #expect(ManagedChargeLimit.desiredLimit(target: 60, hold: nil, calibrationLimit: nil, canWriteBelowThreshold: true) == 60)
        #expect(ManagedChargeLimit.desiredLimit(target: 60, hold: hold, calibrationLimit: nil, canWriteBelowThreshold: true) == 75)
        #expect(ManagedChargeLimit.desiredLimit(target: 60, hold: hold, calibrationLimit: 15, canWriteBelowThreshold: true) == 15)
        #expect(ManagedChargeLimit.desiredLimit(target: 60, hold: nil, calibrationLimit: nil, canWriteBelowThreshold: false) == 80)
        #expect(ManagedChargeLimit.desiredLimit(target: 60, hold: hold, calibrationLimit: 100, canWriteBelowThreshold: false) == 100)
    }

    private func state(
        limit: ChargeLimitSetting? = .on(percent: 60), plugged: Bool = true,
        registration: ChargeLimitRegistration? = ChargeLimitRegistration(limits: [60, 60]),
        policy: SystemChargeState? = nil, otherTool: Bool = false, desired: Int = 60
    ) -> ManagedLimitState {
        ManagedLimitState.resolve(
            desired: desired, target: 60, requested: 60,
            snapshot: BatterySnapshot(isExternalPower: plugged, chargeLimit: limit, systemChargeState: policy),
            registration: registration, isOtherToolRunning: otherTool
        )
    }

    @Test func confirmsBothPowerUIAndRegistration() {
        #expect(state() == .applied)
        #expect(state(limit: .on(percent: 80)) == .pending)
        #expect(state(registration: ChargeLimitRegistration(limits: [])) == .awaitingRegistration)
        #expect(state(registration: nil) == .awaitingRegistration)
        #expect(state(plugged: false, registration: ChargeLimitRegistration(limits: [])) == .appliesWhenPluggedIn)
        #expect(state(desired: 80) == .awaitingHelperApproval(effective: 80))
        #expect(state(policy: .calibrating) == .systemPolicy(.systemCalibration, limit: 60))
        #expect(state(policy: .calibrating, otherTool: true) == .blockedByOtherTool)
    }

    @Test func policyPriorityAndFullChargeDetection() {
        let snapshot = BatterySnapshot(systemChargeState: .calibrating, isFullChargeOverrideActive: true)
        #expect(snapshot.activeChargePolicies == [.systemCalibration, .fullChargeOverride])
        #expect(snapshot.isSystemFullChargeActive)
        #expect(!BatterySnapshot(systemChargeState: .temporaryFullCharge).isSystemFullChargeActive)
        #expect(BatterySnapshot(systemChargeState: .optimizedChargingDischarging(limit: 75)).activeChargePolicies == [.optimizedCharging])
    }

    @Test func parsesActiveManualEntriesAndIgnoresOtherPolicies() throws {
        let registration = try #require(ChargeLimitRegistration.parse("""
            Battery level limits:
            (
            {
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 60;
                Terminated = 0;
            },
            {
                chargeSocLimitReason = "manualChargeLimit";
                chargeSocLimitSoc = 60;
                Terminated = 0;
            },
            {
                chargeSocLimitReason = optimizedCharging;
                chargeSocLimitSoc = 80;
                Terminated = 0;
            },
            {
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 75;
                Terminated = 1;
            }
            )
            """))
        #expect(registration.limits == [60, 60])
        #expect(registration.registers(60))
        #expect(!ChargeLimitRegistration(limits: [60, 80]).registers(60))
        #expect(ChargeLimitRegistration.parse("No battery level limits set")?.registers(100) == true)
        #expect(ChargeLimitRegistration.parse("Battery level limits:\n(\n)")?.registers(100) == true)
    }

    @Test(arguments: ["", "new format", "Battery level limits:\n(\nunknown format\n)", "Battery level limits:\n(\n{\nchargeSocLimitSoc = 60;", "warning: No battery level limits set; read failed"])
    func unrecognizedRegistrationIsUnknown(_ output: String) {
        #expect(ChargeLimitRegistration.parse(output) == nil)
    }

    @Test func validatesPreferenceTypesAndRecoveryMarker() {
        #expect(ManualChargeLimitPreferences.isValid(featureState: nil, limitValue: nil))
        #expect(ManualChargeLimitPreferences.isValid(featureState: NSNumber(value: 1), limitValue: NSNumber(value: 15)))
        #expect(!ManualChargeLimitPreferences.isValid(featureState: NSNumber(value: true), limitValue: NSNumber(value: 60)))
        #expect(!ManualChargeLimitPreferences.isValid(featureState: NSNumber(value: 1), limitValue: NSNumber(value: 60.5)))
        #expect(!ManualChargeLimitPreferences.isValid(featureState: 1, limitValue: "60"))
        #expect(!ChargeHelperMarker(featureState: 3, limitValue: 60).isValid)
        #expect(ChargeHelperMarker(featureState: 1, limitValue: 15).restoredLimit == 80)
        #expect(ChargeHelperMarker(featureState: 0, limitValue: 80).restoredLimit == nil)
    }

    @Test func helperLabelsCarryVersionSuffix() {
        #expect(ChargeHelper.isValidLabel("io.github.nanvon.hachibu.helper"))
        #expect(ChargeHelper.isValidLabel("io.github.nanvon.hachibu.helper.0.1.11"))
        #expect(ChargeHelper.isValidLabel("io.github.nanvon.hachibu.helper.0.1.11.debug"))
        #expect(!ChargeHelper.isValidLabel("io.github.nanvon.hachibu.helper."))
        #expect(!ChargeHelper.isValidLabel("io.github.nanvon.hachibu.helperx"))
        #expect(!ChargeHelper.isValidLabel("io.github.nanvon.hachibu.helper.0 1"))
        #expect(!ChargeHelper.isValidLabel("com.example.helper.0.1.11"))
        #expect(ChargeHelper.plistName(for: "io.github.nanvon.hachibu.helper.0.1.11") == "io.github.nanvon.hachibu.helper.0.1.11.plist")
        // 测试进程的 Info.plist 没有这个 key，退回固定 label。
        #expect(ChargeHelper.label == ChargeHelper.legacyLabel)
    }
}
