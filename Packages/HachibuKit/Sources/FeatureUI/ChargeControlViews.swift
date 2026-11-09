import BatteryCore
import SwiftUI

/// 面板和设置页共用的接管、校准文案和视图。规则见 docs/v1技术设计.md 21.7。

/// 校准进度的展示数据，只依赖进度和读数，渲染测试直接构造。
struct CalibrationDisplay: Equatable {
    var step: CalibrationStep
    var pauseReason: CalibrationPauseReason?
    var fraction: Double?
    var remainingMinutes: Int?

    init(step: CalibrationStep, pauseReason: CalibrationPauseReason? = nil, fraction: Double? = nil, remainingMinutes: Int? = nil) {
        self.step = step
        self.pauseReason = pauseReason
        self.fraction = fraction
        self.remainingMinutes = remainingMinutes
    }

    init(progress: CalibrationProgress, snapshot: BatterySnapshot) {
        self.init(
            step: progress.step,
            pauseReason: progress.pauseReason,
            fraction: progress.stepFraction(snapshot: snapshot),
            remainingMinutes: progress.isPaused ? nil : progress.remainingMinutes(snapshot: snapshot)
        )
    }

    @MainActor
    init?(monitor: BatteryMonitor) {
        guard let progress = monitor.calibration, case .battery(let snapshot)? = monitor.reading else { return nil }
        self.init(progress: progress, snapshot: snapshot)
    }
}

/// 校准块里的操作。
enum CalibrationAction: Equatable {
    case pause, resume, skip, redo, cancel
    /// 退出后未完成的校准：放弃，记为中断。
    case discard
    /// 系统充满时趁现在完成校准，从第 3 步开始。
    case startAfterSystemFullCharge
}

extension BatteryMonitor {
    func perform(_ action: CalibrationAction) {
        switch action {
        case .pause: pauseCalibration()
        case .resume: resumeCalibration()
        case .skip: skipCalibrationStep()
        case .redo: redoCalibrationStep()
        case .cancel: cancelCalibration()
        case .discard: cancelCalibration(abandoned: true)
        case .startAfterSystemFullCharge:
            startCalibration(from: .dischargeToLow, kind: .afterSystemFullCharge, earlierCompletion: .alreadySatisfied)
        }
    }
}

extension CalibrationStep {
    var title: Text {
        switch self {
        case .chargeToFull: Text("Charge to 100%", bundle: .module)
        case .holdFull: Text("Hold at 100%", bundle: .module)
        case .dischargeToLow: Text("Discharge to \(CalibrationStep.dischargeTarget)%", bundle: .module)
        case .rechargeToFull: Text("Charge to 100% Again", bundle: .module)
        case .holdFullAgain: Text("Hold at 100% Again", bundle: .module)
        case .restoreLimit: Text("Return to Charge Limit", bundle: .module)
        }
    }

    /// 面板状态行，如“校准：放电至 15%”。
    var statusText: Text {
        switch self {
        case .chargeToFull, .rechargeToFull: Text("Calibration: Charging to 100%", bundle: .module)
        case .holdFull, .holdFullAgain: Text("Calibration: Holding at 100%", bundle: .module)
        case .dischargeToLow: Text("Calibration: Discharging to \(CalibrationStep.dischargeTarget)%", bundle: .module)
        case .restoreLimit: Text("Calibration: Returning to Limit", bundle: .module)
        }
    }
}

extension CalibrationPauseReason {
    var note: Text {
        switch self {
        case .user: Text("Paused. Your charge limit applies until you resume.", bundle: .module)
        case .appQuit: Text("Calibration was not finished when Hachibu quit.", bundle: .module)
        case .unplugged: Text("Paused. Plug in the power adapter to continue.", bundle: .module)
        case .systemPolicy: Text("Paused while macOS charges to full. Continues afterwards.", bundle: .module)
        case .otherTool: Text("Paused because another charge control app is running.", bundle: .module)
        case .writeFailed: Text("Paused because the charge limit could not be changed. Retrying.", bundle: .module)
        case .helperUnavailable: Text("Paused. Approve the Hachibu background item in Settings to continue.", bundle: .module)
        }
    }
}

/// 接管模式说明行：现在谁在控制、结束后回到多少。
struct ManagedLimitNote: View {
    let control: ChargeLimitControl

    var body: some View {
        if control.isBlocked {
            note(Text("Another charge control app is running. macOS settings apply until it quits.", bundle: .module))
        } else if control.writeFailed {
            note(Text("Could not change the charge limit. Retrying.", bundle: .module), color: .red)
        } else if control.showsExternalChangeNotice, control.managedState == .applied {
            note(Text("The charge limit is managed by Hachibu. Changes in System Settings are reverted.", bundle: .module))
        } else if let state = control.managedState {
            note(Self.text(state))
        }
    }

    private func note(_ text: Text, color: Color = .secondary) -> some View {
        text
            .foregroundStyle(color)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func text(_ state: ManagedLimitState) -> Text {
        switch state {
        case .applied: Text("Managed by Hachibu.", bundle: .module)
        case .pending: Text("Applying. Takes effect in about a second.", bundle: .module)
        case .awaitingRegistration: Text("Waiting for macOS to apply the limit.", bundle: .module)
        case .appliesWhenPluggedIn: Text("Takes effect when you plug in.", bundle: .module)
        case .awaitingHelperApproval(let effective):
            Text("Waiting for the background item to be approved. Using \(effective)% for now.", bundle: .module)
        case .systemPolicy(let policy, let limit):
            switch policy {
            case .systemCalibration, .fullChargeOverride:
                limit < 100
                    ? Text("macOS is calibrating the battery. Returns to \(limit)% afterwards.", bundle: .module)
                    : Text("macOS is calibrating the battery.", bundle: .module)
            case .temporaryFullCharge:
                limit < 100
                    ? Text("Temporary full charge. Returns to \(limit)% afterwards.", bundle: .module)
                    : Text("Temporary full charge.", bundle: .module)
            case .optimizedCharging:
                Text("Optimized Battery Charging is on and may hold the charge lower. Turn it off in Battery settings.", bundle: .module)
            }
        case .blockedByOtherTool:
            Text("Another charge control app is running. macOS settings apply until it quits.", bundle: .module)
        }
    }
}

/// 校准进行中时代替充电上限块：第几步、步骤名、进度条、预计剩余时间、暂停 / 继续，其余操作在“…”菜单里。
struct CalibrationTile: View {
    let display: CalibrationDisplay
    let onAction: @MainActor (CalibrationAction) -> Void
    @Environment(\.rendersStaticControls) private var rendersStaticControls
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                CalibrationSymbol()
                Text("Battery Calibration", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text("Step \(display.step.rawValue) of \(CalibrationStep.allCases.count)", bundle: .module)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline) {
                display.step.title
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                if let remaining = display.remainingMinutes, remaining > 0 {
                    Text("About \(DisplayFormat.duration(minutes: remaining, locale: locale)) left", bundle: .module)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            CalibrationBar(fraction: display.fraction ?? 0, isPaused: display.pauseReason != nil)
            HStack(alignment: .center, spacing: 8) {
                if let reason = display.pauseReason {
                    reason.note
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                buttons
            }
        }
        .panelTile()
    }

    @ViewBuilder
    private var buttons: some View {
        if display.pauseReason == .appQuit {
            pill(Text("Discard", bundle: .module), .discard)
            pill(Text("Continue", bundle: .module), .resume)
        } else {
            if display.pauseReason == .user {
                pill(Text("Resume", bundle: .module), .resume)
            } else {
                pill(Text("Pause", bundle: .module), .pause)
            }
            moreMenu
        }
    }

    private func pill(_ title: Text, _ action: CalibrationAction) -> some View {
        Button { onAction(action) } label: {
            title
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 4)
        }
        .panelGlassButtonStyle()
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .focusable(false)
    }

    @ViewBuilder
    private var moreMenu: some View {
        let label = Image(systemName: "ellipsis")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 14, height: 14)
        if rendersStaticControls {
            Button {} label: { label }
                .panelGlassButtonStyle()
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .focusable(false)
        } else {
            Menu {
                Button { onAction(.skip) } label: { Text("Skip This Step", bundle: .module) }
                    .disabled(display.step == .restoreLimit)
                Button { onAction(.redo) } label: { Text("Redo This Step", bundle: .module) }
                Divider()
                Button(role: .destructive) { onAction(.cancel) } label: { Text("Cancel Calibration", bundle: .module) }
            } label: {
                label
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .panelGlassButtonStyle()
            .controlSize(.small)
            .buttonBorderShape(.circle)
            .fixedSize()
            .focusable(false)
            .accessibilityLabel(Text("More", bundle: .module))
        }
    }
}

private struct CalibrationSymbol: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.brand)
            .frame(width: 24, height: 24)
            .background {
                Circle().fill(LinearGradient(
                    colors: [Color.brand.opacity(dark ? 0.3 : 0.16), Color.brand.opacity(dark ? 0.18 : 0.24)],
                    startPoint: .top, endPoint: .bottom
                ))
            }
    }
}

/// 当前步骤的进度条。暂停时用次要色。
struct CalibrationBar: View {
    let fraction: Double
    let isPaused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07))
                Capsule()
                    .fill(isPaused ? AnyShapeStyle(Color.secondary.opacity(0.6)) : AnyShapeStyle(Color.brand))
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 6))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: DisplayFormat.percent(Int((fraction * 100).rounded()))))
    }
}
