import BatteryCore
import SwiftUI

/// 菜单栏面板的内容。窗口定位、关闭、焦点由 App 层的 PanelController 负责。
/// 显示规则见 docs/v1技术设计.md 第 7、8 节，布局和样式见第 19.2 节。
public struct PanelRootView: View {
    private let monitor: BatteryMonitor
    private let settings: AppSettings
    private let onOpenMainWindow: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    public init(
        monitor: BatteryMonitor,
        settings: AppSettings,
        onOpenMainWindow: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit
    }

    public var body: some View {
        PanelContent(
            reading: monitor.reading,
            health: monitor.health,
            highTemperatureCelsius: settings.temperatureAlertThreshold,
            chargeLimitControl: ChargeLimitControl(monitor: monitor),
            isFlowAnimating: monitor.isPanelVisible,
            onChangeChargeLimit: { [monitor] change in
                Task { await monitor.setChargeLimit(change) }
            },
            onOpenMainWindow: onOpenMainWindow,
            onQuit: onQuit
        )
        // 面板成为 key window 时系统会把第一个控件设为焦点，开启“键盘导航”后会画焦点环，这里统一不显示。
        .focusEffectDisabled()
    }
}

/// 面板内容只依赖读数，预览时直接传入示例数据。
private struct PanelContent: View {
    let reading: BatteryReading?
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int
    let chargeLimitControl: ChargeLimitControl?
    let isFlowAnimating: Bool
    let onChangeChargeLimit: @MainActor (ChargeLimitChange) -> Void
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            switch reading {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .noBattery:
                Text("No Battery Detected", bundle: .module)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 80)
            case .battery(let snapshot):
                BatteryPanelContent(
                    snapshot: snapshot,
                    health: health,
                    highTemperatureCelsius: highTemperatureCelsius,
                    chargeLimitControl: chargeLimitControl,
                    isFlowAnimating: isFlowAnimating,
                    onChangeChargeLimit: onChangeChargeLimit
                )
            }

            PanelFooter(
                lowPowerModeEnabled: snapshot?.lowPowerModeEnabled,
                onOpenMainWindow: onOpenMainWindow,
                onQuit: onQuit
            )
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 360)
        .lineLimit(1)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: reading)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: health)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: chargeLimitControl)
    }

    private var snapshot: BatterySnapshot? {
        if case .battery(let snapshot) = reading { snapshot } else { nil }
    }
}

/// 从上到下：功率流、电量 / 温度 / 功率、系统充电上限、电池健康、详细数据。
private struct BatteryPanelContent: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int
    let chargeLimitControl: ChargeLimitControl?
    let isFlowAnimating: Bool
    let onChangeChargeLimit: @MainActor (ChargeLimitChange) -> Void

    var body: some View {
        PowerTile(snapshot: snapshot, isFlowAnimating: isFlowAnimating)
        MetricsRow(snapshot: snapshot, highTemperatureCelsius: highTemperatureCelsius)
        if let chargeLimitControl {
            ChargeLimitTile(control: chargeLimitControl, onChange: onChangeChargeLimit)
        }
        HealthTile(snapshot: snapshot, health: health)
        DetailsTile(snapshot: snapshot)
    }
}

// MARK: - 功率

/// 标题行为状态文字和更新时间，下面是功率流向图。
private struct PowerTile: View {
    let snapshot: BatterySnapshot
    let isFlowAnimating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusLabel(status: ChargeStatus(snapshot))
                    .font(.system(size: 13, weight: .semibold))
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if let updatedAt = snapshot.telemetryUpdatedAt {
                    UpdatedAgoText(date: updatedAt)
                }
            }
            if let flow = PowerFlow(snapshot) {
                PowerFlowView(flow: flow, isAnimating: isFlowAnimating)
            }
        }
        .panelTile()
    }
}

/// 状态文字和图标。充电相关用绿色，接电放电用橙色，其他用次要色。
struct StatusLabel: View {
    let status: ChargeStatus?

    var body: some View {
        HStack(spacing: 4) {
            if let status {
                Image(systemName: Self.symbolName(status))
                    .foregroundStyle(Self.tint(status))
            }
            Self.text(status)
        }
    }

    private static func symbolName(_ status: ChargeStatus) -> String {
        switch status {
        case .onBattery: "battery.75percent"
        case .charging: "bolt.fill"
        case .pluggedInDraining, .fullyCharged, .chargeLimitReached, .pluggedInNotCharging: "powerplug.fill"
        }
    }

    private static func tint(_ status: ChargeStatus) -> Color {
        switch status {
        case .charging, .fullyCharged, .chargeLimitReached: .green
        case .pluggedInDraining: .orange
        case .onBattery, .pluggedInNotCharging: .secondary
        }
    }

    private static func text(_ status: ChargeStatus?) -> Text {
        switch status {
        case .onBattery: Text("On Battery", bundle: .module)
        case .charging: Text("Charging", bundle: .module)
        case .pluggedInDraining: Text("Plugged In, Draining", bundle: .module)
        case .fullyCharged: Text("Fully Charged", bundle: .module)
        case .chargeLimitReached(let limit): Text("Charge Limit Reached (\(limit)%)", bundle: .module)
        case .pluggedInNotCharging: Text("Plugged In, Not Charging", bundle: .module)
        case nil: Text(verbatim: DisplayFormat.missing)
        }
    }
}

/// 功率遥测约每 60 秒刷新一次，标注距离 `UpdateTime` 的秒数。
private struct UpdatedAgoText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(date)))
            Text("Updated \(seconds)s ago", bundle: .module)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - 电量、温度、功率

private struct MetricsRow: View {
    let snapshot: BatterySnapshot
    /// 温度达到该值时显示“偏高”，即设置里的温度提醒阈值。
    let highTemperatureCelsius: Int

    var body: some View {
        HStack(spacing: 8) {
            MetricCard(
                symbol: "battery.75percent",
                tint: .brand,
                label: Text("Battery Level", bundle: .module),
                value: DisplayFormat.percent(snapshot.percent),
                detail: remainingText
            )
            MetricCard(
                symbol: "thermometer.medium",
                tint: .red,
                label: Text("Temperature", bundle: .module),
                value: DisplayFormat.celsius(snapshot.temperatureCelsius),
                detail: Text("Battery", bundle: .module),
                badge: isTemperatureHigh ? Text("High", bundle: .module) : nil
            )
            MetricCard(
                symbol: "gauge.with.dots.needle.67percent",
                tint: .systemPower,
                label: Text("Power", bundle: .module),
                value: DisplayFormat.watts(milliwatts: snapshot.systemLoadMW),
                detail: Text("System", bundle: .module)
            )
        }
    }

    private var remainingText: Text {
        switch snapshot.remainingTime {
        case .untilEmpty(let minutes):
            Text("\(DisplayFormat.duration(minutes: minutes)) remaining", bundle: .module)
        case .untilFull(let minutes):
            Text("\(DisplayFormat.duration(minutes: minutes)) until full", bundle: .module)
        case nil:
            Text(verbatim: DisplayFormat.missing)
        }
    }

    private var isTemperatureHigh: Bool {
        guard let temperature = snapshot.temperatureCelsius else { return false }
        return temperature >= Double(highTemperatureCelsius)
    }
}

/// 一个读数卡片：图标和标签（右侧可带“偏高”标签），大号数值，下面一行小字说明。
private struct MetricCard: View {
    let symbol: String
    let tint: Color
    let label: Text
    let value: String
    let detail: Text
    var badge: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.small)
                label
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let badge {
                    badge
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .fixedSize()
                }
            }
            .font(.system(size: 11.5))
            Text(verbatim: value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .padding(.top, 6)
            detail
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .minimumScaleFactor(0.8)
                .padding(.top, 1)
        }
        .panelTile(padding: EdgeInsets(top: 10, leading: 12, bottom: 11, trailing: 12))
    }
}

// MARK: - 充电上限

/// 系统充电上限：标题行右侧为开关，开启时下方为档位。AlDente 运行时禁用并说明原因。
private struct ChargeLimitTile: View {
    let control: ChargeLimitControl
    let onChange: @MainActor (ChargeLimitChange) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("System Charge Limit", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                Toggle(isOn: Binding(get: { control.isEnabled }, set: { onChange($0 ? .enable : .disable) })) {
                    Text("System Charge Limit", bundle: .module)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!control.isInteractive)
            }
            if control.isEnabled {
                LimitSegments(options: control.options, selection: control.percent) { onChange(.limit($0)) }
                    .disabled(!control.isInteractive)
                    .transition(PanelMotion.transition(reduceMotion: reduceMotion))
            }
            ChargeLimitNote(control: control)
                .font(.caption)
        }
        .panelTile()
    }
}

/// 铺满宽度的分段档位。系统 `.segmented` 在 macOS 上按内容宽度显示，不能铺满，所以用按钮画。
private struct LimitSegments: View {
    let options: [Int]
    let selection: Int?
    let onSelect: @MainActor (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { percent in
                segment(percent, isSelected: percent == selection)
            }
        }
        .padding(2)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Limit", bundle: .module))
    }

    private func segment(_ percent: Int, isSelected: Bool) -> some View {
        Button {
            if !isSelected {
                onSelect(percent)
            }
        } label: {
            Text(verbatim: DisplayFormat.percent(percent))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.2) : Color.white)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// AlDente 运行或修改失败时的说明，面板和设置页共用。
struct ChargeLimitNote: View {
    let control: ChargeLimitControl

    var body: some View {
        if control.isBlocked {
            Text("Quit AlDente to change the charge limit here.", bundle: .module)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        } else if control.writeFailed {
            Text("Could not change the charge limit.", bundle: .module)
                .foregroundStyle(.red)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 电池健康

/// 一行三列：系统最大容量、满充容量、循环次数；健康状态在标题行右侧。
private struct HealthTile: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Battery Health", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let conditionText {
                    conditionText
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                HealthValue(label: Text("Maximum Capacity", bundle: .module), value: DisplayFormat.percent(health?.systemMaximumCapacityPercent))
                HealthValue(
                    label: Text("Full Charge Capacity", bundle: .module),
                    value: DisplayFormat.number(snapshot.fullChargeCapacityMAh),
                    unit: snapshot.fullChargeCapacityMAh == nil ? nil : "mAh"
                )
                HealthValue(label: Text("Cycle Count", bundle: .module), value: DisplayFormat.number(snapshot.cycleCount))
            }
        }
        .panelTile()
    }

    /// `"Good"` 显示为本地化文字，其他值原样显示英文原文。
    private var conditionText: Text? {
        switch health?.condition {
        case .good: Text("Good", bundle: .module)
        case .other(let value): Text(verbatim: value)
        case nil: nil
        }
    }
}

private struct HealthValue: View {
    let label: Text
    let value: String
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            label
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.75)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(verbatim: unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 详细数据

/// 电压、电流等不常看的读数，默认折叠，展开状态存 `UserDefaults`。接电时加上充电器信息。
private struct DetailsTile: View {
    let snapshot: BatterySnapshot
    @AppStorage("panelDetailsExpanded") private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isExternalPower: Bool {
        snapshot.isExternalPower == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(PanelMotion.animation(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Details", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !isExpanded {
                        Group {
                            if isExternalPower {
                                Text("Voltage, Current, Charger", bundle: .module)
                            } else {
                                Text("Voltage, Current", bundle: .module)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("On", bundle: .module) : Text("Off", bundle: .module))

            if isExpanded {
                VStack(spacing: 6) {
                    ValueRow(Text("Battery Voltage", bundle: .module), value: DisplayFormat.volts(millivolts: snapshot.voltageMV, fractionLength: 2))
                    ValueRow(Text("Battery Current", bundle: .module), value: DisplayFormat.amps(milliamps: snapshot.amperageMA))
                    ValueRow(Text("Battery Power", bundle: .module), value: DisplayFormat.signedWatts(milliwatts: snapshot.batteryPowerMW))
                    Divider()
                    ValueRow(Text("Design Capacity", bundle: .module), value: designCapacity)
                    ValueRow(Text("Capacity Ratio (Full Charge / Design)", bundle: .module), value: DisplayFormat.percent(ratio: snapshot.capacityRatio))
                    if isExternalPower {
                        Divider()
                        ValueRow(Text("Charger", bundle: .module), value: adapter)
                            .help(Text(verbatim: adapterDescription))
                        ValueRow(Text("Input Voltage · Current", bundle: .module), value: chargerInput)
                    }
                }
                .padding(.top, 10)
                .transition(PanelMotion.transition(reduceMotion: reduceMotion))
            }
        }
        .panelTile(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    }

    private var designCapacity: String {
        snapshot.designCapacityMAh.map { "\($0) mAh" } ?? DisplayFormat.missing
    }

    /// 充电器名称，读不到时用额定功率。额定功率和厂商放在悬停提示里。
    private var adapter: String {
        snapshot.adapter.flatMap { adapter in adapter.name ?? adapter.watts.map { "\($0) W" } } ?? DisplayFormat.missing
    }

    private var adapterDescription: String {
        [snapshot.adapter?.watts.map { "\($0) W" }, snapshot.adapter?.manufacturer].compactMap { $0 }.joined(separator: " · ")
    }

    private var chargerInput: String {
        "\(DisplayFormat.volts(millivolts: snapshot.inputVoltageMV, fractionLength: 1)) · \(DisplayFormat.amps(milliamps: snapshot.inputCurrentMA))"
    }
}

private struct ValueRow: View {
    let label: Text
    let value: String

    init(_ label: Text, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            label
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .fontWeight(.medium)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.system(size: 12))
    }
}

// MARK: - 底部

private struct PanelFooter: View {
    /// 没有电池读数时为 nil，不显示低电量模式。
    let lowPowerModeEnabled: Bool?
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let lowPowerModeEnabled {
                LowPowerModeBadge(isEnabled: lowPowerModeEnabled)
            }
            Button {
                onOpenMainWindow()
            } label: {
                Text("Open Main Window", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .panelGlassButtonStyle()
            .controlSize(.large)
            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .panelGlassButtonStyle()
            .controlSize(.large)
            .buttonBorderShape(.circle)
            .help(Text("Quit", bundle: .module))
            .accessibilityLabel(Text("Quit", bundle: .module))
        }
    }
}

/// 低电量模式状态胶囊：开启时黄色（与系统电池图标一致），关闭时为浅色块、次要色。宽度不够时只显示图标和开关状态。
private struct LowPowerModeBadge: View {
    let isEnabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            badge(showsTitle: true)
            badge(showsTitle: false)
        }
        .help(Text("Low Power Mode", bundle: .module))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Low Power Mode", bundle: .module))
        .accessibilityValue(stateText)
    }

    private func badge(showsTitle: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "battery.50percent")
            if showsTitle {
                Text("Low Power Mode", bundle: .module)
            }
            stateText
        }
        .font(.system(size: 11.5))
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            if isEnabled {
                Capsule().fill(Color.yellow.opacity(0.3))
            } else {
                Capsule().fill(PanelTileStyle.fill(colorScheme))
                Capsule().strokeBorder(PanelTileStyle.edge, lineWidth: 0.5)
            }
        }
        .fixedSize()
    }

    /// 短写的“开 / 关”，与其他地方的“开启 / 关闭”分开。
    private var stateText: Text {
        isEnabled ? Text("On (Short)", bundle: .module) : Text("Off (Short)", bundle: .module)
    }
}

// MARK: - 预览

#if DEBUG
/// 面板各状态的示例数据，数值参考 docs/v1技术设计.md 第 5 节的本机实测值。
private enum PanelPreviewData {
    static let health = BatteryHealthInfo(systemMaximumCapacityPercent: 95, condition: .good)
    static let adapter = PowerAdapter(watts: 140, name: "140W USB-C Power Adapter", manufacturer: "Apple Inc.")

    static func snapshot(
        percent: Int? = 80,
        isExternalPower: Bool? = true,
        isCharging: Bool? = false,
        batteryPowerMW: Int? = 0,
        powerInMW: Int? = 14514,
        systemLoadMW: Int? = 14514,
        amperageMA: Int? = 0,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil,
        chargeLimit: ChargeLimitSetting? = .on(percent: 80),
        temperatureCelsius: Double? = 26.69
    ) -> BatterySnapshot {
        BatterySnapshot(
            percent: percent,
            isExternalPower: isExternalPower,
            isCharging: isCharging,
            timeToEmptyMinutes: timeToEmptyMinutes,
            timeToFullMinutes: timeToFullMinutes,
            voltageMV: 12244,
            amperageMA: amperageMA,
            batteryPowerMW: batteryPowerMW,
            powerInMW: isExternalPower == true ? powerInMW : 0,
            systemLoadMW: systemLoadMW,
            inputVoltageMV: isExternalPower == true ? 28008 : nil,
            inputCurrentMA: isExternalPower == true ? 518 : nil,
            telemetryUpdatedAt: Date().addingTimeInterval(-12),
            temperatureCelsius: temperatureCelsius,
            fullChargeCapacityMAh: 7942,
            designCapacityMAh: 8694,
            cycleCount: 68,
            designCycleCount: 1000,
            adapter: isExternalPower == true ? adapter : nil,
            chargeLimit: chargeLimit,
            chargeLimitOptions: [80, 85, 90, 95, 100]
        )
    }
}

/// 模拟面板的玻璃底板。
private struct PanelPreview: View {
    let reading: BatteryReading?
    var health: BatteryHealthInfo? = PanelPreviewData.health
    var isChargeControlAppRunning = false

    /// 预览按可以写入处理，显示充电上限控制。
    private var chargeLimitControl: ChargeLimitControl? {
        guard case .battery(let snapshot)? = reading else { return nil }
        return ChargeLimitControl(snapshot: snapshot, canWrite: true, isBlocked: isChargeControlAppRunning)
    }

    var body: some View {
        PanelContent(
            reading: reading,
            health: health,
            highTemperatureCelsius: 40,
            chargeLimitControl: chargeLimitControl,
            isFlowAnimating: true,
            onChangeChargeLimit: { _ in },
            onOpenMainWindow: {},
            onQuit: {}
        )
        .panelGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(24)
    }
}

#Preview("On Battery") {
    PanelPreview(reading: .battery(PanelPreviewData.snapshot(
        percent: 64,
        isExternalPower: false,
        batteryPowerMW: -9800,
        systemLoadMW: 9800,
        amperageMA: -820,
        timeToEmptyMinutes: 312
    )))
}

#Preview("Charging") {
    PanelPreview(reading: .battery(PanelPreviewData.snapshot(
        percent: 46,
        isCharging: true,
        batteryPowerMW: 42000,
        powerInMW: 58000,
        systemLoadMW: 16000,
        amperageMA: 3400,
        timeToFullMinutes: 48,
        temperatureCelsius: 41.2
    )))
}

#Preview("Plugged In, Draining") {
    PanelPreview(reading: .battery(PanelPreviewData.snapshot(
        percent: 72,
        batteryPowerMW: -12000,
        powerInMW: 30000,
        systemLoadMW: 42000,
        amperageMA: -980
    )))
}

#Preview("Plugged In, Not Charging") {
    PanelPreview(reading: .battery(PanelPreviewData.snapshot()))
}

#Preview("Charge Limit Off, AlDente Running") {
    PanelPreview(
        reading: .battery(PanelPreviewData.snapshot(isCharging: true, batteryPowerMW: 30000, chargeLimit: .off)),
        isChargeControlAppRunning: true
    )
}

#Preview("No Battery") {
    PanelPreview(reading: .noBattery, health: nil)
}

#Preview("Missing Data") {
    PanelPreview(reading: .battery(BatterySnapshot(isExternalPower: false)), health: nil)
}
#endif
