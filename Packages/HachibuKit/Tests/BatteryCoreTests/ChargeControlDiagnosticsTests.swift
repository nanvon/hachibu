import Foundation
import Testing
@testable import BatteryCore

@Suite struct ChargeControlDiagnosticsTests {
    @Test func oldFileWithoutChargeControlDecodes() throws {
        let report = try Fixtures.report(Fixtures.onBattery)
        #expect(report.chargeControl == nil)
        // 没有该字段时不写出空键。
        let json = try #require(String(data: report.jsonData(), encoding: .utf8))
        #expect(!json.contains("chargeControl"))
    }

    @Test func chargeControlRoundTrips() throws {
        var report = try Fixtures.report(Fixtures.charging)
        let calibration = CalibrationProgress(
            start: .manual, step: CalibrationStep.allCases[0], at: Date(timeIntervalSince1970: 1_800_000_000), percent: 60
        )
        let status = ChargeHelperStatus(
            version: 1, isSchemaSupported: true, featureState: 2, limitValue: 60, isPreferenceValid: true,
            hasMarker: true, isMarkerCorrupt: false, keepsLimit: false, leaseRemainingSeconds: 90
        )
        report.chargeControl = ChargeControlDiagnostics(
            mode: ChargeControlMode.managed.rawValue,
            target: 60,
            keepsLimitOnQuit: false,
            helperState: "enabled",
            helperStatus: status,
            battlimitOutput: "No battery level limits",
            registration: ChargeLimitRegistration(limits: []),
            calibration: calibration,
            managedLimitState: "applied"
        )
        let decoded = try DiagnosticReport(jsonData: report.jsonData())
        #expect(decoded.chargeControl == report.chargeControl)
        #expect(decoded == report)
    }
}
