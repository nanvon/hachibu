import Foundation
import Testing
@testable import BatteryCore

@Suite struct CalibrationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func progress(_ step: CalibrationStep) -> CalibrationProgress {
        CalibrationProgress(start: .manual, step: step, at: start, percent: 80)
    }

    private func input(
        seconds: TimeInterval = 0, percent: Int? = 100, plugged: Bool? = true, charging: Bool? = false,
        policy: Bool = false, helper: Bool = true, otherTool: Bool = false, failing: Bool = false,
        applied: Bool = false
    ) -> CalibrationInput {
        CalibrationInput(
            now: start.addingTimeInterval(seconds),
            snapshot: BatterySnapshot(
                percent: percent, isExternalPower: plugged, isCharging: charging, isFullChargeOverrideActive: policy
            ),
            isOtherToolRunning: otherTool, canWriteBelowThreshold: helper,
            isWriteFailing: failing, isTargetApplied: applied
        )
    }

    @Test func completeSixStepCycle() throws {
        var current = progress(.chargeToFull)
        for (seconds, percent, next) in [
            (0.0, 100, CalibrationStep.holdFull),
            (1.0, 100, .holdFull),
            (3601.0, 99, .dischargeToLow),
            (4000.0, 15, .rechargeToFull),
            (5000.0, 100, .holdFullAgain),
            (5001.0, 100, .holdFullAgain),
            (8601.0, 100, .restoreLimit),
        ] {
            current = try #require(CalibrationEngine.evaluate(current, input: input(seconds: seconds, percent: percent)).progress)
            #expect(current.step == next)
        }
        #expect(CalibrationEngine.evaluate(current, input: input(seconds: 8700)).progress != nil)
        let finished = CalibrationEngine.evaluate(current, input: input(seconds: 8701, applied: true))
        #expect(finished.progress == nil)
        #expect(finished.events == [.stepFinished(.restoreLimit, .reached), .finished(.completed)])
    }

    @Test(arguments: [CalibrationStep.chargeToFull, .rechargeToFull])
    func fullChargeRequiresStoppedCharging(_ step: CalibrationStep) {
        #expect(CalibrationEngine.evaluate(progress(step), input: input(charging: true)).progress?.step == step)
        #expect(CalibrationEngine.evaluate(progress(step), input: input(percent: nil)).progress?.step == step)
        #expect(CalibrationEngine.evaluate(progress(step), input: input(plugged: false)).progress?.pauseReason == .unplugged)
    }

    @Test func holdExcludesPausedTimeButIncludesPluggedSleep() throws {
        let holding = try #require(CalibrationEngine.evaluate(progress(.holdFull), input: input()).progress)
        let paused = try #require(CalibrationEngine.evaluate(holding, input: input(seconds: 600, plugged: false)).progress)
        #expect(paused.pauseReason == .unplugged)
        #expect(paused.holdSeconds == 0)
        let resumed = try #require(CalibrationEngine.evaluate(paused, input: input(seconds: 1200)).progress)
        #expect(resumed.holdSeconds == 0)
        #expect(CalibrationEngine.evaluate(resumed, input: input(seconds: 4800)).progress?.step == .dischargeToLow)
    }

    @Test func relaunchCannotCountTimeWhileAppWasClosed() throws {
        var holding = progress(.holdFull)
        holding.lastHoldTick = start
        holding.holdSeconds = 300
        let restored = CalibrationEngine.pauseForRelaunch(holding)
        #expect(restored.pauseReason == .appQuit)
        let resumed = CalibrationEngine.setUserPaused(false, restored)
        let result = try #require(CalibrationEngine.evaluate(resumed, input: input(seconds: 7200)).progress)
        #expect(result.step == .holdFull)
        #expect(result.holdSeconds == 300)
    }

    @Test func holdBelow99StopsCountingWithoutResetting() throws {
        var holding = progress(.holdFull)
        holding.holdSeconds = 600
        holding.lastHoldTick = start
        let low = try #require(CalibrationEngine.evaluate(holding, input: input(seconds: 300, percent: 98)).progress)
        let restored = try #require(CalibrationEngine.evaluate(low, input: input(seconds: 1800)).progress)
        #expect(restored.holdSeconds == 600)
    }

    @Test func dischargePausesForPolicyOrMissingHelperAndAllowsBatteryUse() {
        let current = progress(.dischargeToLow)
        #expect(CalibrationEngine.evaluate(current, input: input(policy: true)).progress?.pauseReason == .systemPolicy)
        #expect(CalibrationEngine.evaluate(current, input: input(helper: false)).progress?.pauseReason == .helperUnavailable)
        #expect(CalibrationEngine.evaluate(current, input: input(percent: 15, plugged: false)).progress?.step == .rechargeToFull)
        #expect(CalibrationEngine.evaluate(current, input: input(percent: nil)).progress?.step == .dischargeToLow)
    }

    @Test func manualPauseOverridesAutomaticResumeAndRestoresTarget() throws {
        let paused = CalibrationEngine.setUserPaused(true, progress(.dischargeToLow))
        let result = try #require(CalibrationEngine.evaluate(paused, input: input(percent: 15)).progress)
        #expect(result.pauseReason == .user)
        #expect(result.step == .dischargeToLow)
        #expect(CalibrationEngine.requestedLimit(for: result) == nil)
        let resumed = CalibrationEngine.setUserPaused(false, result)
        #expect(CalibrationEngine.evaluate(resumed, input: input(percent: 15)).progress?.step == .rechargeToFull)
    }

    @Test func otherToolAndWriteFailurePauseAllSteps() {
        let current = progress(.chargeToFull)
        #expect(CalibrationEngine.evaluate(current, input: input(otherTool: true)).progress?.pauseReason == .otherTool)
        #expect(CalibrationEngine.evaluate(current, input: input(failing: true)).progress?.pauseReason == .writeFailed)
    }

    @Test func skipRedoAndSuggestedStartingStep() throws {
        let skipped = CalibrationEngine.start(.manual, from: .dischargeToLow, earlierCompletion: .skipped, at: start, percent: 80)
        #expect(skipped.events.contains(.stepFinished(.holdFull, .skipped)))
        #expect(CalibrationEngine.skip(progress(.dischargeToLow), at: start, percent: 60).progress?.step == .rechargeToFull)
        #expect(CalibrationEngine.skip(progress(.restoreLimit), at: start, percent: 60).events.isEmpty)
        var holding = progress(.holdFull)
        holding.holdSeconds = 600
        let redone = try #require(CalibrationEngine.redo(holding, at: start, percent: 99).progress)
        #expect(redone.holdSeconds == 0)
        #expect(redone.lastHoldTick == nil)
        #expect(CalibrationEngine.suggestedStart(percent: 99, heldFullForLastHour: true) == .chargeToFull)
        #expect(CalibrationEngine.suggestedStart(percent: 100, heldFullForLastHour: false) == .holdFull)
        #expect(CalibrationEngine.suggestedStart(percent: 100, heldFullForLastHour: true) == .dischargeToLow)
    }

    @Test func dischargeEstimateUsesEnergyAndSystemLoad() {
        let current = progress(.dischargeToLow)
        let snapshot = BatterySnapshot(percent: 65, voltageMV: 12_000, systemLoadMW: 12_000, fullChargeCapacityMAh: 8000)
        #expect(current.remainingMinutes(snapshot: snapshot) == 240)
        #expect(current.stepFraction(snapshot: BatterySnapshot(percent: 15)) == 1)
        #expect(current.remainingMinutes(snapshot: BatterySnapshot(percent: 65)) == nil)
    }
}
