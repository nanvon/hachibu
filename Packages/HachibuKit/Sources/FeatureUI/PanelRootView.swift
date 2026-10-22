import BatteryCore
import SwiftUI

/// 菜单栏面板的内容。窗口定位、关闭、焦点由 App 层的 PanelController 负责。
/// 显示规则见 docs/v1技术设计.md 第 7、8 节。
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
        VStack(alignment: .leading, spacing: 12) {
            switch monitor.reading {
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
                    health: monitor.health,
                    highTemperatureCelsius: settings.temperatureAlertThreshold
                )
            }

            Divider()

            HStack {
                Button {
                    onOpenMainWindow()
                } label: {
                    Text("Open Main Window", bundle: .module)
                }
                Spacer()
                Button {
                    onQuit()
                } label: {
                    Text("Quit", bundle: .module)
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

private struct BatteryPanelContent: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int

    var body: some View {
        StatusHeader(snapshot: snapshot)
        if let flow = PowerFlow(snapshot) {
            PowerCard(flow: flow, isExternalPower: snapshot.isExternalPower == true, updatedAt: snapshot.telemetryUpdatedAt)
        }
        HealthCard(snapshot: snapshot, health: health)
        LiveCard(snapshot: snapshot, highTemperatureCelsius: highTemperatureCelsius)
        if snapshot.isExternalPower == true {
            ChargerCard(snapshot: snapshot)
        }
        LowPowerModeRow(isEnabled: snapshot.lowPowerModeEnabled)
    }
}

// MARK: - 状态头部

private struct StatusHeader: View {
    let snapshot: BatterySnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: DisplayFormat.percent(snapshot.percent))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Self.statusText(ChargeStatus(snapshot))
                    .font(.headline)
                remainingText
                    .font(.subheadline)
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

    static func statusText(_ status: ChargeStatus?) -> Text {
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

private struct PowerCard: View {
    let flow: PowerFlow
    let isExternalPower: Bool
    let updatedAt: Date?

    var body: some View {
        PanelCard(Text("Power", bundle: .module)) {
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

// MARK: - 电池健康

private struct HealthCard: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?

    var body: some View {
        PanelCard(Text("Battery Health", bundle: .module)) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: DisplayFormat.percent(health?.systemMaximumCapacityPercent))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("Maximum Capacity", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                conditionText
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ValueRow(Text("Cycle Count", bundle: .module), value: cycleCount)
            ValueRow(
                Text("Full Charge / Design", bundle: .module),
                value: "\(DisplayFormat.number(snapshot.fullChargeCapacityMAh)) / \(DisplayFormat.number(snapshot.designCapacityMAh)) mAh"
            )
            ValueRow(Text("Capacity Ratio", bundle: .module), value: DisplayFormat.percent(ratio: snapshot.capacityRatio))
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

// MARK: - 实时

private struct LiveCard: View {
    let snapshot: BatterySnapshot
    /// 温度达到该值时显示“偏高”，即设置里的温度提醒阈值。
    let highTemperatureCelsius: Int

    var body: some View {
        PanelCard(Text("Live", bundle: .module)) {
            HStack(alignment: .top, spacing: 8) {
                LiveValue(
                    label: Text("Temperature", bundle: .module),
                    value: DisplayFormat.celsius(snapshot.temperatureCelsius),
                    badge: isTemperatureHigh ? Text("High", bundle: .module) : nil
                )
                LiveValue(
                    label: Text("Voltage", bundle: .module),
                    value: DisplayFormat.volts(millivolts: snapshot.voltageMV, fractionLength: 2)
                )
                LiveValue(
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

private struct LiveValue: View {
    let label: Text
    let value: String
    var badge: Text?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                if let badge {
                    badge
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 充电器

private struct ChargerCard: View {
    let snapshot: BatterySnapshot

    var body: some View {
        PanelCard(Text("Charger", bundle: .module)) {
            if let adapter = snapshot.adapter, adapter.name != nil || adapter.manufacturer != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let name = adapter.name {
                        Text(verbatim: name)
                            .font(.callout.weight(.medium))
                    }
                    if let manufacturer = adapter.manufacturer {
                        Text(verbatim: manufacturer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ValueRow(Text("Rated Power", bundle: .module), value: DisplayFormat.watts(snapshot.adapter?.watts))
            ValueRow(
                Text("Input", bundle: .module),
                value: "\(DisplayFormat.volts(millivolts: snapshot.inputVoltageMV, fractionLength: 1)) · \(DisplayFormat.amps(milliamps: snapshot.inputCurrentMA))"
            )
        }
    }
}

// MARK: - 低电量模式

private struct LowPowerModeRow: View {
    let isEnabled: Bool

    var body: some View {
        HStack {
            Text("Low Power Mode", bundle: .module)
            Spacer()
            if isEnabled {
                Text("On", bundle: .module)
            } else {
                Text("Off", bundle: .module)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}

// MARK: - 通用

private let cardCornerRadius: CGFloat = 14

private struct PanelCard<Accessory: View, Content: View>: View {
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
    }
}

extension PanelCard where Accessory == EmptyView {
    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
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
