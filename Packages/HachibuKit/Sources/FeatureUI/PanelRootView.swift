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
            onOpenMainWindow: onOpenMainWindow,
            onQuit: onQuit
        )
    }
}

/// 面板内容只依赖读数，预览时直接传入示例数据。
private struct PanelContent: View {
    let reading: BatteryReading?
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int
    let onOpenMainWindow: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch reading {
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            case .noBattery:
                Text("No Battery Detected", bundle: .module)
                    .font(.headline)
            case .battery(let snapshot):
                BatteryPanelContent(
                    snapshot: snapshot,
                    health: health,
                    highTemperatureCelsius: highTemperatureCelsius
                )
            }

            PanelFooter(
                lowPowerModeEnabled: snapshot?.lowPowerModeEnabled,
                onOpenMainWindow: onOpenMainWindow,
                onQuit: onQuit
            )
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: reading)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: health)
    }

    private var snapshot: BatterySnapshot? {
        if case .battery(let snapshot) = reading { snapshot } else { nil }
    }
}

private struct BatteryPanelContent: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StatusHeader(snapshot: snapshot)
        if let flow = PowerFlow(snapshot) {
            PowerSection(flow: flow, isExternalPower: snapshot.isExternalPower == true, updatedAt: snapshot.telemetryUpdatedAt)
        }
        LiveSection(snapshot: snapshot, highTemperatureCelsius: highTemperatureCelsius)
        HealthSection(snapshot: snapshot, health: health)
        if snapshot.isExternalPower == true {
            ChargerRow(snapshot: snapshot)
                .transition(PanelMotion.transition(reduceMotion: reduceMotion))
        }
    }
}

// MARK: - 状态头部

private struct StatusHeader: View {
    let snapshot: BatterySnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            BowlGauge(percent: snapshot.percent, chargeLimitPercent: snapshot.chargeLimitPercent)
                .frame(width: 56, height: 45)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: DisplayFormat.percent(snapshot.percent))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(snapshot.percent ?? 0)))
                StatusLabel(status: ChargeStatus(snapshot))
                    .font(.subheadline.weight(.medium))
                remainingText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
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
}

/// 状态文字和图标。充电相关用绿色，接电放电用橙色，其他用次要色。
private struct StatusLabel: View {
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

// MARK: - 功率

private struct PowerSection: View {
    let flow: PowerFlow
    let isExternalPower: Bool
    let updatedAt: Date?

    var body: some View {
        PanelSection(Text("Power", bundle: .module)) {
            if let updatedAt {
                UpdatedAgoText(date: updatedAt)
            }
        } content: {
            PowerFlowView(flow: flow, isExternalPower: isExternalPower)
            if let caption = flow.caption {
                Self.captionText(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 说明句只陈述数值，不推断原因。
    private static func captionText(_ caption: PowerFlow.Caption) -> Text {
        switch caption {
        case let .charging(inputMW, loadMW, batteryMW):
            Text(
                "Charger input \(DisplayFormat.watts(milliwatts: inputMW)): computer using \(DisplayFormat.watts(milliwatts: loadMW)), charging battery \(DisplayFormat.watts(milliwatts: batteryMW)).",
                bundle: .module
            )
        case let .pluggedInIdle(loadMW):
            Text("Charger supplies \(DisplayFormat.watts(milliwatts: loadMW)) to the computer; battery not charging.", bundle: .module)
        case let .pluggedInDraining(inputMW, batteryMW, loadMW):
            Text(
                "Charger input \(DisplayFormat.watts(milliwatts: inputMW)), battery supplying \(DisplayFormat.watts(milliwatts: batteryMW)), computer using \(DisplayFormat.watts(milliwatts: loadMW)).",
                bundle: .module
            )
        case let .onBattery(loadMW):
            Text("Computer running on battery: \(DisplayFormat.watts(milliwatts: loadMW)).", bundle: .module)
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - 实时

private struct LiveSection: View {
    let snapshot: BatterySnapshot
    /// 温度达到该值时显示“偏高”，即设置里的温度提醒阈值。
    let highTemperatureCelsius: Int

    var body: some View {
        PanelSection(Text("Live", bundle: .module)) {
            HStack(alignment: .top, spacing: 8) {
                MetricTile(
                    symbol: "thermometer.medium",
                    tint: .red,
                    label: Text("Temperature", bundle: .module),
                    value: DisplayFormat.celsius(snapshot.temperatureCelsius),
                    badge: isTemperatureHigh ? Text("High", bundle: .module) : nil,
                    badgeTint: .orange
                )
                MetricTile(
                    symbol: "bolt.fill",
                    tint: .brand,
                    label: Text("Voltage", bundle: .module),
                    value: DisplayFormat.volts(millivolts: snapshot.voltageMV, fractionLength: 2)
                )
                MetricTile(
                    symbol: "arrow.left.arrow.right",
                    tint: .brand,
                    label: Text("Current", bundle: .module),
                    value: DisplayFormat.amps(milliamps: snapshot.amperageMA)
                )
            }
        }
    }

    private var isTemperatureHigh: Bool {
        guard let temperature = snapshot.temperatureCelsius else { return false }
        return temperature >= Double(highTemperatureCelsius)
    }
}

// MARK: - 电池健康

private struct HealthSection: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?
    @AppStorage("panelHealthDetailsExpanded") private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelSection(Text("Battery Health", bundle: .module)) {
            Button {
                withAnimation(PanelMotion.animation(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 3) {
                    Text("Details", bundle: .module)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("On", bundle: .module) : Text("Off", bundle: .module))
        } content: {
            HStack(alignment: .top, spacing: 8) {
                MetricTile(
                    symbol: "heart.fill",
                    tint: .brand,
                    label: Text("Maximum Capacity", bundle: .module),
                    value: DisplayFormat.percent(health?.systemMaximumCapacityPercent),
                    badge: conditionText,
                    badgeTint: .secondary
                )
                MetricTile(
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .brand,
                    label: Text("Cycle Count", bundle: .module),
                    value: cycleCount
                )
            }
            if isExpanded {
                VStack(spacing: 6) {
                    ValueRow(
                        Text("Full Charge / Design", bundle: .module),
                        value: "\(DisplayFormat.number(snapshot.fullChargeCapacityMAh)) / \(DisplayFormat.number(snapshot.designCapacityMAh)) mAh"
                    )
                    ValueRow(Text("Capacity Ratio", bundle: .module), value: DisplayFormat.percent(ratio: snapshot.capacityRatio))
                }
                .transition(PanelMotion.transition(reduceMotion: reduceMotion))
            }
        }
    }

    /// `"Good"` 显示为本地化文字，其他值原样显示英文原文。
    private var conditionText: Text? {
        switch health?.condition {
        case .good: Text("Good", bundle: .module)
        case .other(let value): Text(verbatim: value)
        case nil: nil
        }
    }

    private var cycleCount: String {
        guard let cycleCount = snapshot.cycleCount else { return DisplayFormat.missing }
        guard let designCycleCount = snapshot.designCycleCount else { return "\(cycleCount)" }
        return "\(cycleCount) / \(designCycleCount)"
    }
}

// MARK: - 充电器

/// 只在接电时显示：额定功率（读不到时用名称）· 输入电压 · 输入电流。名称和厂商放在悬停提示里。
private struct ChargerRow: View {
    let snapshot: BatterySnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "powerplug.fill")
                .foregroundStyle(.green)
            Text("Charger", bundle: .module)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(verbatim: summary)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .font(.callout)
        .help(Text(verbatim: adapterDescription))
    }

    private var summary: String {
        let adapter = snapshot.adapter.flatMap { adapter in adapter.watts.map { "\($0) W" } ?? adapter.name }
        return [
            adapter ?? DisplayFormat.missing,
            DisplayFormat.volts(millivolts: snapshot.inputVoltageMV, fractionLength: 1),
            DisplayFormat.amps(milliamps: snapshot.inputCurrentMA),
        ].joined(separator: " · ")
    }

    private var adapterDescription: String {
        [snapshot.adapter?.name, snapshot.adapter?.manufacturer].compactMap { $0 }.joined(separator: " · ")
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
            Spacer(minLength: 8)
            Button {
                onOpenMainWindow()
            } label: {
                Text("Open Main Window", bundle: .module)
            }
            .panelGlassButtonStyle()
            .layoutPriority(1)
            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .panelGlassButtonStyle()
            .buttonBorderShape(.circle)
            .help(Text("Quit", bundle: .module))
            .accessibilityLabel(Text("Quit", bundle: .module))
            .layoutPriority(1)
        }
    }
}

/// 低电量模式状态胶囊：开启时黄色（与系统电池图标一致），关闭时次要色。宽度不够时只显示图标和开关状态。
private struct LowPowerModeBadge: View {
    let isEnabled: Bool

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
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isEnabled ? Color.yellow.opacity(0.25) : Color.primary.opacity(0.06), in: Capsule())
        .fixedSize()
    }

    private var stateText: Text {
        isEnabled ? Text("On", bundle: .module) : Text("Off", bundle: .module)
    }
}

// MARK: - 通用

/// 面板中的一组内容：小标题行（右侧可放附加内容）加内容，不加背景。
private struct PanelSection<Accessory: View, Content: View>: View {
    private let title: Text
    private let accessory: Accessory
    private let content: Content

    init(_ title: Text, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                title
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// 一个读数：彩色图标和小标签，下面是大号数值，数值后可跟一个标签（如“偏高”“状态良好”）。
private struct MetricTile: View {
    let symbol: String
    let tint: Color
    let label: Text
    let value: String
    var badge: Text?
    var badgeTint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.small)
                label
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.caption)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
                if let badge {
                    badge
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeTint)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .monospacedDigit()
        }
        .font(.callout)
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
        chargeLimitPercent: Int? = 80,
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
            chargeLimitPercent: chargeLimitPercent
        )
    }
}

/// 模拟面板的玻璃底板。
private struct PanelPreview: View {
    let reading: BatteryReading?
    var health: BatteryHealthInfo? = PanelPreviewData.health

    var body: some View {
        PanelContent(
            reading: reading,
            health: health,
            highTemperatureCelsius: 40,
            onOpenMainWindow: {},
            onQuit: {}
        )
        .panelGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
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

#Preview("No Battery") {
    PanelPreview(reading: .noBattery, health: nil)
}

#Preview("Missing Data") {
    PanelPreview(reading: .battery(BatterySnapshot(isExternalPower: false)), health: nil)
}
#endif
