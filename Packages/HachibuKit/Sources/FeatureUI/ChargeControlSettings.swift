import AppKit
import BatteryCore
import HistoryStore
import SwiftUI

// 设置页“电池充电”分组的接管部分和“电池校准”分组。规则见 docs/v1技术设计.md 21.3、21.6、21.7。

extension ChargeControlMode {
    var title: Text {
        switch self {
        case .followSystem: Text("Follow System Settings", bundle: .module)
        case .managed: Text("Managed by Hachibu", bundle: .module)
        }
    }
}

extension ManagedLimitOnQuit {
    var title: Text {
        switch self {
        case .restoreSystem: Text("Restore System Settings", bundle: .module)
        case .keepLimit: Text("Keep Current Limit", bundle: .module)
        }
    }
}

extension AfterSystemFullCharge {
    var title: Text {
        switch self {
        case .dischargeToLimit: Text("Discharge to Limit", bundle: .module)
        case .continueCalibration: Text("Finish Calibration", bundle: .module)
        }
    }
}

/// “充电上限管理”菜单。切到接管模式时目标取系统当前的上限。
struct ChargeControlModeRow: View {
    @Bindable var settings: AppSettings
    let snapshot: BatterySnapshot
    let isDisabled: Bool

    var body: some View {
        SettingsRow(
            Text("Charge Limit Control", bundle: .module),
            subtitle: settings.chargeControlMode == .managed
                ? Text("Hachibu keeps its own limit while it runs. Choose what happens when it quits below.", bundle: .module)
                : nil
        ) {
            SettingsMenu(
                selection: Binding(
                    get: { settings.chargeControlMode },
                    set: { mode in
                        if mode == .managed, settings.chargeControlMode != .managed {
                            settings.managedChargeLimit = snapshot.chargeLimitHold?.userLimit
                                ?? ManagedChargeLimit.limit(of: snapshot.chargeLimit) ?? settings.managedChargeLimit
                        }
                        settings.chargeControlMode = mode
                    }
                ),
                options: ChargeControlMode.allCases,
                title: \.title,
                label: Text("Charge Limit Control", bundle: .module)
            )
            .disabled(isDisabled)
        }
    }
}

/// 接管模式的充电上限：档位加步进器（精确到 1%），退出后的处理，后台组件，当前状态。
struct ManagedChargeLimitRows: View {
    @Bindable var settings: AppSettings
    let control: ChargeLimitControl
    let snapshot: BatterySnapshot
    let monitor: BatteryMonitor
    @Binding var pendingHelperInstall: Bool
    @State private var pendingRemoval = false
    @State private var removalFailed = false
    @State private var helperStatus: ChargeHelperStatus?

    var body: some View {
        SettingsRow(Text("Charge Limit", bundle: .module)) {
            SettingsStepper(
                value: $settings.managedChargeLimit,
                range: ManagedChargeLimit.targetRange,
                text: settings.managedChargeLimit >= 100 ? String(localized: "Off", bundle: .module) : DisplayFormat.percent(settings.managedChargeLimit),
                label: Text("Charge Limit", bundle: .module)
            )
            .disabled(control.isBlocked)
        }
        LimitSegments(options: control.options, selection: control.percent) { settings.managedChargeLimit = $0 }
            .disabled(control.isBlocked)
            .padding(.bottom, 10)
        ManagedLimitNote(control: control)
            .font(.system(size: 11.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)

        SettingsRowDivider()
        SettingsRow(Text("After Quitting Hachibu", bundle: .module)) {
            SettingsMenu(
                selection: $settings.managedLimitOnQuit,
                options: ManagedLimitOnQuit.allCases,
                title: \.title,
                label: Text("After Quitting Hachibu", bundle: .module)
            )
        }

        if showsHelperRow {
            SettingsRowDivider()
            helperRow
        }
        if helperStatus?.isMarkerCorrupt == true {
            SettingsNote(text: Text("The saved system limit could not be read. Check the charge limit in System Settings before removing the background item.", bundle: .module), isError: true)
        }
        if removalFailed {
            SettingsNote(text: Text("Could not safely remove the background item. Check the charge limit and try again.", bundle: .module), isError: true)
        }
    }

    private var helper: ChargeHelperService { monitor.helperService }

    private var showsHelperRow: Bool {
        helper.state != .notRegistered || settings.managedChargeLimit < ManagedChargeLimit.helperThreshold
    }

    @ViewBuilder
    private var helperRow: some View {
        SettingsRow(
            Text("Background Item", bundle: .module),
            subtitle: ChargeHelperService.isBelowThresholdSupported
                ? Text("Needed for limits below 80% and battery calibration. It runs as root and can only change the charge limit.", bundle: .module)
                : Text("Limits below 80% are not available on this version of macOS yet.", bundle: .module)
        ) {
            HStack(spacing: 10) {
                helperPill
                switch helper.state {
                case .notRegistered:
                    Button { pendingHelperInstall = true } label: { Text("Install…", bundle: .module) }
                        .settingsButtonStyle()
                        .disabled(!ChargeHelperService.isBelowThresholdSupported)
                case .requiresApproval:
                    Button { helper.openLoginItems() } label: { Text("Open Login Items Settings…", bundle: .module) }
                        .settingsButtonStyle()
                case .enabled, .unavailable:
                    Button { pendingRemoval = true } label: { Text("Remove…", bundle: .module) }
                        .settingsButtonStyle()
                        .disabled(monitor.isWritingChargeLimit)
                }
            }
        }
        .alert(
            Text("Remove Background Item?", bundle: .module),
            isPresented: $pendingRemoval
        ) {
            Button(role: .destructive) {
                if settings.managedChargeLimit < ManagedChargeLimit.helperThreshold {
                    settings.managedChargeLimit = ManagedChargeLimit.helperThreshold
                }
                Task { removalFailed = !(await monitor.removeChargeHelper()) }
            } label: {
                Text("Remove", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Hachibu first returns the charge limit to 80% or higher, then removes the background item. Limits below 80% and calibration will no longer be available.", bundle: .module)
        }
        .task(id: helper.state) { helperStatus = await helper.helperStatus() }
    }

    private var helperPill: some View {
        switch helper.state {
        case .notRegistered: StatusPill(text: Text("Not Installed", bundle: .module))
        case .requiresApproval: StatusPill(text: Text("Waiting for Approval", bundle: .module), tint: .orange)
        case .enabled: StatusPill(text: Text("Enabled", bundle: .module), tint: .green)
        case .unavailable: StatusPill(text: Text("Unavailable", bundle: .module), tint: .red)
        }
    }
}

/// 安装后台组件前的说明，确认后注册；需要批准时打开“登录项与扩展”。
struct ChargeHelperInstallAlert: ViewModifier {
    @Binding var isPresented: Bool
    let helper: ChargeHelperService

    func body(content: Content) -> some View {
        content.alert(Text("Install Background Item?", bundle: .module), isPresented: $isPresented) {
            Button { helper.register() } label: { Text("Install", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Not Now", bundle: .module) }
        } message: {
            Text("Charge limits below 80% and battery calibration need a background item that runs as root. It can only change the charge limit. After installing, approve Hachibu in System Settings → General → Login Items & Extensions. Until then, Hachibu uses 80%.", bundle: .module)
        }
    }
}

/// 设置页“当前状态”行的说明：系统实际登记的上限。
struct RegistrationSubtitle {
    static func text(_ registration: ChargeLimitRegistration?) -> Text? {
        guard let registration else { return nil }
        if registration.limits.isEmpty { return Text("macOS has no charge limit registered.", bundle: .module) }
        guard let limit = registration.limit else { return Text("macOS has conflicting charge limits registered.", bundle: .module) }
        return Text("macOS is enforcing \(limit)%.", bundle: .module)
    }
}

// MARK: - 电池校准

/// 设置页“电池校准”分组，只在接管模式下显示。
struct CalibrationSettingsGroup: View {
    @Bindable var settings: AppSettings
    let monitor: BatteryMonitor
    @Binding var pendingHelperInstall: Bool
    @State private var startStep: CalibrationStep?
    @State private var suggestedStep: CalibrationStep = .chargeToFull
    @State private var pendingStart = false
    @State private var runs: [CalibrationRun] = []
    @State private var lastFullCharge: Date?
    @State private var showsAllRecords = false
    @Environment(\.locale) private var locale

    var body: some View {
        SettingsGroup(
            Text("Battery Calibration", bundle: .module),
            description: Text("Charges to 100%, holds for an hour, discharges to 15% while plugged in, then charges to 100% again before returning to your limit. Takes about half a day and adds about one charge cycle. Macs with Apple silicon generally don't need manual calibration.", bundle: .module)
        ) {
            if let progress = monitor.calibration {
                runningRows(progress)
            } else {
                idleRows
            }
            SettingsRowDivider()
            SettingsRow(
                Text("After macOS Charges to Full", bundle: .module),
                subtitle: Text("macOS sometimes charges to 100% to calibrate the battery. Hachibu can use that full charge to finish a calibration.", bundle: .module)
            ) {
                SettingsMenu(
                    selection: $settings.afterSystemFullCharge,
                    options: AfterSystemFullCharge.allCases,
                    title: \.title,
                    label: Text("After macOS Charges to Full", bundle: .module)
                )
            }
            SettingsRowDivider()
            SettingsRow(Text("macOS Last Charged to Full", bundle: .module)) {
                Text(verbatim: lastFullCharge.map { $0.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale)) } ?? DisplayFormat.missing)
                    .foregroundStyle(.secondary)
            }
            if !runs.isEmpty {
                SettingsRowDivider()
                CalibrationRecordRows(runs: runs)
                if showsAllRecords || runs.count >= 5 {
                    SettingsPanelFooter {
                        Button {
                            showsAllRecords.toggle()
                            Task { await reload() }
                        } label: {
                            showsAllRecords
                                ? Text("Show Recent Records", bundle: .module)
                                : Text("Show All Records", bundle: .module)
                        }
                        .settingsButtonStyle()
                    }
                }
            }
        }
        .task(id: monitor.calibration == nil) { await reload() }
        .alert(Text("Start Battery Calibration?", bundle: .module), isPresented: $pendingStart) {
            Button {
                let step = startStep ?? suggestedStep
                monitor.startCalibration(from: step, earlierCompletion: startStep == nil ? .alreadySatisfied : .skipped)
            } label: {
                Text("Start", bundle: .module)
            }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            Text("Keep your Mac plugged in. Calibration takes about half a day; discharging to 15% while plugged in can take 5 to 8 hours when the Mac is idle. It starts from step \((startStep ?? suggestedStep).rawValue). If you quit Hachibu, your limit is restored and you can continue later.", bundle: .module)
        }
    }

    @ViewBuilder
    private var idleRows: some View {
        SettingsRow(Text("Start From", bundle: .module)) {
            SettingsMenu(
                selection: $startStep,
                options: [nil] + CalibrationStep.allCases.filter { $0 != .restoreLimit }.map(Optional.some),
                title: { step in
                    step.map { Text("Step \($0.rawValue): \($0.title)", bundle: .module) }
                        ?? Text("Automatic (Step \(suggestedStep.rawValue))", bundle: .module)
                },
                label: Text("Start From", bundle: .module)
            )
        }
        SettingsRowDivider()
        SettingsPanelFooter {
            Button {
                if monitor.helperService.isReady {
                    Task {
                        suggestedStep = await monitor.suggestedCalibrationStart()
                        pendingStart = true
                    }
                } else if monitor.helperService.state == .requiresApproval {
                    monitor.helperService.openLoginItems()
                } else {
                    pendingHelperInstall = true
                }
            } label: {
                Text("Start Calibration…", bundle: .module)
            }
            .settingsButtonStyle()
            .disabled(monitor.isChargeControlAppRunning || !ChargeHelperService.isBelowThresholdSupported)
        }
        if !monitor.helperService.isReady {
            SettingsNote(text: Text("Calibration needs the background item to discharge to 15%.", bundle: .module))
        }
    }

    @ViewBuilder
    private func runningRows(_ progress: CalibrationProgress) -> some View {
        ForEach(CalibrationStep.allCases, id: \.self) { step in
            CalibrationStepRow(step: step, progress: progress, snapshot: snapshot)
        }
        if let reason = progress.pauseReason {
            SettingsNote(text: reason.note)
        }
        SettingsRowDivider()
        SettingsPanelFooter {
            HStack(spacing: 8) {
                if progress.pauseReason == .appQuit {
                    Button { monitor.perform(.resume) } label: { Text("Continue", bundle: .module) }
                        .settingsButtonStyle()
                    Button { monitor.perform(.discard) } label: { Text("Discard", bundle: .module) }
                        .settingsButtonStyle()
                } else {
                    if progress.pauseReason == .user {
                        Button { monitor.perform(.resume) } label: { Text("Resume", bundle: .module) }
                            .settingsButtonStyle()
                    } else {
                        Button { monitor.perform(.pause) } label: { Text("Pause", bundle: .module) }
                            .settingsButtonStyle()
                    }
                    Button { monitor.perform(.skip) } label: { Text("Skip This Step", bundle: .module) }
                        .settingsButtonStyle()
                        .disabled(progress.step == .restoreLimit)
                    Button { monitor.perform(.cancel) } label: { Text("Cancel Calibration", bundle: .module) }
                        .settingsButtonStyle()
                }
            }
        }
    }

    private var snapshot: BatterySnapshot? {
        if case .battery(let snapshot)? = monitor.reading { snapshot } else { nil }
    }

    private func reload() async {
        runs = await monitor.calibrationHistory(limit: showsAllRecords ? Int.max : 5)
        lastFullCharge = await monitor.lastFullChargeDate()
        suggestedStep = await monitor.suggestedCalibrationStart()
    }
}

/// 进行中校准的一步：已完成打勾，当前高亮并显示进度。
private struct CalibrationStepRow: View {
    let step: CalibrationStep
    let progress: CalibrationProgress
    let snapshot: BatterySnapshot?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text("Step \(step.rawValue)", bundle: .module)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            step.title
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(step < progress.step ? .secondary : .primary)
            Spacer(minLength: 8)
            if isCurrent, let snapshot {
                if let fraction = progress.stepFraction(snapshot: snapshot) {
                    CalibrationBar(fraction: fraction, isPaused: progress.isPaused)
                        .frame(width: 80)
                }
                if !progress.isPaused, let minutes = progress.remainingMinutes(snapshot: snapshot), minutes > 0 {
                    Text("About \(DisplayFormat.duration(minutes: minutes, locale: locale)) left", bundle: .module)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(minHeight: 30)
    }

    private var isCurrent: Bool { step == progress.step }

    private var symbol: String {
        if step < progress.step { return "checkmark.circle.fill" }
        if isCurrent { return progress.isPaused ? "pause.circle.fill" : "circle.dotted.circle" }
        return "circle"
    }

    private var tint: Color {
        if step < progress.step { return .green }
        if isCurrent { return progress.isPaused ? .orange : .brand }
        return .secondary
    }
}

/// 最近的校准记录：日期、时长、结果、满充容量变化（仅供参考）。
struct CalibrationRecordRows: View {
    let runs: [CalibrationRun]
    @Environment(\.locale) private var locale

    var body: some View {
        SettingsRow(
            Text("Calibration Records", bundle: .module),
            subtitle: Text("Full charge capacity changes are for reference only.", bundle: .module)
        ) {
            EmptyView()
        }
        ForEach(runs, id: \.id) { run in
            HStack(spacing: 10) {
                Text(verbatim: run.startedAt.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale)))
                    .monospacedDigit()
                Text(verbatim: duration(run))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                if let change = capacityChange(run) {
                    Text(verbatim: change)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                result(run)
            }
            .font(.system(size: 12))
            .frame(minHeight: 26)
        }
        .padding(.bottom, 6)
    }

    private func duration(_ run: CalibrationRun) -> String {
        guard let end = run.endedAt else { return DisplayFormat.missing }
        return DisplayFormat.duration(minutes: Int(end.timeIntervalSince(run.startedAt) / 60), locale: locale)
    }

    private func capacityChange(_ run: CalibrationRun) -> String? {
        guard let before = run.before.fullChargeMAh, let after = run.after?.fullChargeMAh else { return nil }
        let delta = after - before
        return "\(delta >= 0 ? "+" : "−")\(abs(delta)) mAh"
    }

    @ViewBuilder
    private func result(_ run: CalibrationRun) -> some View {
        switch run.result {
        case .completed?: StatusPill(text: Text("Completed", bundle: .module), tint: .green)
        case .cancelled?: StatusPill(text: Text("Cancelled", bundle: .module))
        case .interrupted?: StatusPill(text: Text("Interrupted", bundle: .module), tint: .orange)
        case nil: StatusPill(text: Text("In Progress", bundle: .module), tint: .brand)
        }
    }
}
