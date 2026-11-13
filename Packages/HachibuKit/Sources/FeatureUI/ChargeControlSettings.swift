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

/// 接管模式的充电上限（精确到 1%）和退出后的处理。
struct ManagedChargeLimitRows: View {
    @Bindable var settings: AppSettings
    let control: ChargeLimitControl
    let monitor: BatteryMonitor
    @State private var removalFailed = false
    @State private var helperStatus: ChargeHelperStatus?
    @State private var helperCheckFinished = false

    var body: some View {
        let range = ChargeLimitControl.managedSelectionRange
        SettingsRow(Text("Charge Limit", bundle: .module)) {
            SettingsStepper(
                value: Binding(
                    get: { settings.managedChargeLimit },
                    set: { settings.managedChargeLimit = max($0, range.lowerBound) }
                ),
                // 旧目标低于 70% 时仍显示原值，首次按加号直接调到 70%。
                range: min(settings.managedChargeLimit, range.lowerBound)...range.upperBound,
                text: settings.managedChargeLimit >= 100 ? String(localized: "Off", bundle: .module) : DisplayFormat.percent(settings.managedChargeLimit),
                label: Text("Charge Limit", bundle: .module)
            )
            .disabled(control.isBlocked || monitor.isRemovingChargeHelper)
        }
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
    }
}

/// Hachibu Helper 行：接管模式下始终显示，装过时任何模式都显示，保证随时能移除。
/// 点“安装…”直接注册，不另弹说明，用途和下一步写在行内文字里。
struct ChargeHelperRows: View {
    @Bindable var settings: AppSettings
    let monitor: BatteryMonitor
    @State private var pendingRemoval = false
    @State private var removalFailed = false
    @State private var helperStatus: ChargeHelperStatus?
    @State private var helperCheckFinished = false

    var body: some View {
        helperRow
        helperNotes
    }

    private var helper: ChargeHelperService { monitor.helperService }

    /// 注册、重新安装或移除进行中。
    private var isHelperBusy: Bool { helper.isBusy || monitor.isRemovingChargeHelper }

    /// 系统已允许，但连接 helper 失败。
    private var isHelperUnreachable: Bool {
        helper.state == .enabled && helperCheckFinished && helperStatus == nil
    }

    @ViewBuilder
    private var helperRow: some View {
        SettingsRow(
            Text("Hachibu Helper", bundle: .module),
            subtitle: ChargeHelperService.isBelowThresholdSupported
                ? Text("Only needed for limits below 80% and battery calibration; limits from 80% to 100% work without it. It runs as root and can only change the charge limit.", bundle: .module)
                : Text("Limits below 80% are not available on this version of macOS yet.", bundle: .module)
        ) {
            HStack(spacing: 10) {
                helperPill
                    .fixedSize()
                helperButton
                    .fixedSize()
            }
        }
        .alert(
            Text("Remove Hachibu Helper?", bundle: .module),
            isPresented: $pendingRemoval
        ) {
            Button(role: .destructive) { remove() } label: { Text("Remove", bundle: .module) }
            Button(role: .cancel) {} label: { Text("Cancel", bundle: .module) }
        } message: {
            if monitor.calibration != nil {
                Text("Hachibu first returns the charge limit to 80% or higher, then removes Hachibu Helper and cancels the current calibration. Limits below 80% and calibration will no longer be available.", bundle: .module)
            } else {
                Text("Hachibu first returns the charge limit to 80% or higher, then removes Hachibu Helper. Limits below 80% and calibration will no longer be available.", bundle: .module)
            }
        }
        .task(id: helper.state) { await watchHelper() }
    }

    /// 每个状态只有一个主要操作，放在状态旁边；补救操作放在说明下面。
    @ViewBuilder
    private var helperButton: some View {
        switch helper.state {
        case .notRegistered:
            Button { helper.register() } label: { Text("Install…", bundle: .module) }
                .settingsButtonStyle()
                .focusable(false)
                .disabled(!ChargeHelperService.isBelowThresholdSupported || isHelperBusy)
        case .unavailable:
            // 重新安装解决不了缺少文件，只留说明。
            EmptyView()
        case .requiresApproval:
            Button { helper.openLoginItems() } label: { Text("Open System Settings…", bundle: .module) }
                .settingsButtonStyle()
                .focusable(false)
                .disabled(isHelperBusy)
        case .enabled:
            if isHelperUnreachable {
                Button { Task { await checkHelper() } } label: { Text("Check Again", bundle: .module) }
                    .settingsButtonStyle()
                    .focusable(false)
                    .disabled(isHelperBusy)
            } else {
                Button { pendingRemoval = true } label: { Text("Remove…", bundle: .module) }
                    .settingsButtonStyle()
                    .focusable(false)
                    .disabled(monitor.isWritingChargeLimit || isHelperBusy || !helperCheckFinished)
            }
        }
    }

    @ViewBuilder
    private var helperNotes: some View {
        switch helper.state {
        case .requiresApproval:
            SettingsNote(text: Text("In System Settings → General → Login Items & Extensions, turn on Hachibu under Background App Activity. macOS may ask for your password. If it is already on but this still shows, turn it off and on again, or reinstall.", bundle: .module))
            SettingsPanelFooter {
                Button { pendingRemoval = true } label: { Text("Remove…", bundle: .module) }
                    .settingsButtonStyle()
                    .focusable(false)
                    .disabled(monitor.isWritingChargeLimit || isHelperBusy)
                reinstallButton
            }
        case .enabled where isHelperUnreachable:
            SettingsNote(text: Text("macOS allows Hachibu Helper, but Hachibu can't connect to it. Check again, or reinstall it.", bundle: .module), isError: true)
            SettingsPanelFooter { reinstallButton }
        case .unavailable:
            SettingsNote(text: Text("This copy of Hachibu is missing Hachibu Helper. Download Hachibu again and replace the app.", bundle: .module), isError: true)
        case .notRegistered where ChargeHelperService.isBelowThresholdSupported && !helper.isBusy:
            SettingsNote(text: Text("After you install it, System Settings opens: turn on Hachibu under Background App Activity. macOS may ask for your password.", bundle: .module))
        case .notRegistered, .enabled:
            EmptyView()
        }
        if let error = helper.registrationError, helper.state == .notRegistered {
            SettingsNote(text: Text("Could not install Hachibu Helper: \(error)", bundle: .module), isError: true)
        }
        if helperStatus?.isMarkerCorrupt == true {
            SettingsNote(text: Text("The saved system limit could not be read. Check the charge limit in System Settings before removing Hachibu Helper.", bundle: .module), isError: true)
        }
        if removalFailed {
            if helper.state == .requiresApproval {
                SettingsNote(text: Text("Allow Hachibu Helper first so Hachibu can restore the charge limit, then remove it.", bundle: .module), isError: true)
            } else {
                SettingsNote(text: Text("Could not safely remove Hachibu Helper. Check the charge limit and try again.", bundle: .module), isError: true)
            }
        }
    }

    private var reinstallButton: some View {
        Button {
            removalFailed = false
            Task {
                await helper.reinstall()
                // 状态没变（仍是“已允许”）时 `.task(id:)` 不会重新运行，这里再检查一次连接。
                if helper.state == .enabled { await checkHelper() }
            }
        } label: {
            Text("Reinstall", bundle: .module)
        }
        .settingsButtonStyle()
        .focusable(false)
        .disabled(isHelperBusy || monitor.isWritingChargeLimit)
    }

    /// 移除成功后，低于 80% 的目标已无法生效，改为 80%；失败时目标不变。
    private func remove() {
        removalFailed = false
        Task {
            let removed = await monitor.removeChargeHelper()
            removalFailed = !removed
            if removed, settings.managedChargeLimit < ManagedChargeLimit.helperThreshold {
                settings.managedChargeLimit = ManagedChargeLimit.helperThreshold
            }
        }
    }

    /// 按状态检查连接或等待用户在系统设置里允许。状态变化时 `.task(id:)` 取消并重新运行。
    private func watchHelper() async {
        switch helper.state {
        case .enabled:
            await checkHelper()
            // 刚允许时立即按目标重新判断，不等下一次读数。
            if helperStatus != nil { monitor.publishChargeControl() }
        case .requiresApproval:
            helperStatus = nil
            helperCheckFinished = false
            // 用户在系统设置里打开开关后，菜单栏 App 不一定会收到激活通知，所以定时刷新状态。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                helper.refresh()
            }
        case .notRegistered, .unavailable:
            helperStatus = nil
            helperCheckFinished = false
        }
    }

    private func checkHelper() async {
        helperCheckFinished = false
        let status = await helper.connectedStatus()
        guard !Task.isCancelled else { return }
        helperStatus = status
        helperCheckFinished = true
    }

    @ViewBuilder private var helperPill: some View {
        if monitor.isRemovingChargeHelper {
            StatusPill(text: Text("Removing…", bundle: .module))
        } else if helper.isBusy {
            StatusPill(text: Text("Installing…", bundle: .module))
        } else {
            switch helper.state {
            case .notRegistered: StatusPill(text: Text("Not Installed", bundle: .module))
            case .requiresApproval: StatusPill(text: Text("Needs Permission", bundle: .module), tint: .orange)
            case .enabled:
                if !helperCheckFinished {
                    StatusPill(text: Text("Checking…", bundle: .module))
                } else if helperStatus == nil {
                    StatusPill(text: Text("Not Responding", bundle: .module), tint: .red)
                } else {
                    StatusPill(text: Text("Enabled", bundle: .module), tint: .green)
                }
            case .unavailable: StatusPill(text: Text("Unavailable", bundle: .module), tint: .red)
            }
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
    @State private var startStep: CalibrationStep?
    @State private var suggestedStep: CalibrationStep = .chargeToFull
    @State private var pendingStart = false
    @State private var runs: [CalibrationRun] = []
    @State private var lastCalibration: CalibrationRun?
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
            SettingsRow(Text("Last Calibration", bundle: .module)) {
                HStack(spacing: 8) {
                    Text(verbatim: lastCalibration?.endedAt.map { $0.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(locale)) } ?? DisplayFormat.missing)
                        .foregroundStyle(.secondary)
                    if let lastCalibration {
                        CalibrationResultPill(result: lastCalibration.result)
                    }
                }
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
                Task {
                    suggestedStep = await monitor.suggestedCalibrationStart()
                    pendingStart = true
                }
            } label: {
                Text("Start Calibration…", bundle: .module)
            }
            .settingsButtonStyle()
            .disabled(monitor.isChargeControlAppRunning || !monitor.helperService.isReady)
        }
        if !monitor.helperService.isReady {
            SettingsNote(text: Text("Calibration needs Hachibu Helper to discharge to 15%. Set it up under Battery Charging first.", bundle: .module))
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
        // 进度结束时先等记录写入，避免界面读到尚未结束的旧数据。
        _ = await monitor.calibrationRecordTask?.value
        let history = await monitor.calibrationHistory(limit: Int.max)
        lastCalibration = Self.latestFinishedCalibration(in: history)
        runs = showsAllRecords ? history : Array(history.prefix(5))
        suggestedStep = await monitor.suggestedCalibrationStart()
    }

    static func latestFinishedCalibration(in runs: [CalibrationRun]) -> CalibrationRun? {
        runs.filter { $0.endedAt != nil && $0.result != nil }
            .max { ($0.endedAt ?? .distantPast) < ($1.endedAt ?? .distantPast) }
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
                CalibrationResultPill(result: run.result)
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

}

private struct CalibrationResultPill: View {
    let result: CalibrationResult?

    var body: some View {
        switch result {
        case .completed?: StatusPill(text: Text("Completed", bundle: .module), tint: .green)
        case .cancelled?: StatusPill(text: Text("Cancelled", bundle: .module))
        case .interrupted?: StatusPill(text: Text("Interrupted", bundle: .module), tint: .orange)
        case nil: StatusPill(text: Text("In Progress", bundle: .module), tint: .brand)
        }
    }
}
