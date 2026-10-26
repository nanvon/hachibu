import BatteryCore
import SwiftUI

/// 菜单栏面板的内容。窗口定位、关闭、焦点由 App 层的 PanelController 负责。
/// 显示规则见 docs/v1技术设计.md 第 7、8 节，布局和样式见第 19.2 节。
public struct PanelRootView: View {
    private let monitor: BatteryMonitor
    private let settings: AppSettings
    private let onOpenMainWindow: @MainActor () -> Void
    private let onOpenSettings: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    public init(
        monitor: BatteryMonitor,
        settings: AppSettings,
        onOpenMainWindow: @escaping @MainActor () -> Void,
        onOpenSettings: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.monitor = monitor
        self.settings = settings
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenSettings = onOpenSettings
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
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
        // 面板成为 key window 时系统会把第一个控件设为焦点，开启“键盘导航”后会画焦点环，这里统一不显示。
        .focusEffectDisabled()
        // 与 PanelController 的玻璃底板同圆角。
        .panelOutline(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

/// 面板内容只依赖读数，预览和渲染测试直接传入示例数据。
struct PanelContent: View {
    let reading: BatteryReading?
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int
    let chargeLimitControl: ChargeLimitControl?
    let isFlowAnimating: Bool
    /// 渲染测试用：把功率流光点固定在这个时刻。
    var flowFrozenTime: TimeInterval?
    let onChangeChargeLimit: @MainActor (ChargeLimitChange) -> Void
    let onOpenMainWindow: @MainActor () -> Void
    let onOpenSettings: @MainActor () -> Void
    let onQuit: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
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
                    flowFrozenTime: flowFrozenTime,
                    onChangeChargeLimit: onChangeChargeLimit
                )
            }

            PanelFooter(
                lowPowerModeEnabled: snapshot?.lowPowerModeEnabled,
                onOpenMainWindow: onOpenMainWindow,
                onOpenSettings: onOpenSettings,
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

/// 从上到下：功率流、电量 / 温度 / 功率、系统充电上限、电池健康和详细数据。
private struct BatteryPanelContent: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?
    let highTemperatureCelsius: Int
    let chargeLimitControl: ChargeLimitControl?
    let isFlowAnimating: Bool
    let flowFrozenTime: TimeInterval?
    let onChangeChargeLimit: @MainActor (ChargeLimitChange) -> Void

    var body: some View {
        PowerTile(snapshot: snapshot, isFlowAnimating: isFlowAnimating, flowFrozenTime: flowFrozenTime)
        MetricsRow(
            snapshot: snapshot,
            highTemperatureCelsius: highTemperatureCelsius,
            isAnimating: isFlowAnimating,
            frozenTime: flowFrozenTime
        )
        if let chargeLimitControl {
            ChargeLimitTile(control: chargeLimitControl, onChange: onChangeChargeLimit)
        }
        HealthTile(snapshot: snapshot, health: health)
    }
}

// MARK: - 功率

/// 标题行为状态文字，下面是功率流向图。
private struct PowerTile: View {
    let snapshot: BatterySnapshot
    let isFlowAnimating: Bool
    let flowFrozenTime: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusHeader(status: ChargeStatus(snapshot))
            if let flow = PowerFlow(snapshot) {
                PowerFlowView(flow: flow, isAnimating: isFlowAnimating, frozenTime: flowFrozenTime)
            }
        }
        .panelTile(padding: EdgeInsets(top: 11, leading: 14, bottom: 10, trailing: 14))
    }
}

/// 面板里的状态行：图标放在同色的圆形底上。
private struct StatusHeader: View {
    let status: ChargeStatus?

    var body: some View {
        HStack(spacing: 8) {
            if let status {
                TintedSymbol(name: StatusLabel.symbolName(status), tint: StatusLabel.tint(status), diameter: 24)
            }
            StatusLabel.text(status)
                .font(.system(size: 13.5, weight: .semibold))
                .minimumScaleFactor(0.75)
        }
    }
}

/// 圆形底上的图标。底色为图标颜色的浅色，上浅下深，带一道亮边。
private struct TintedSymbol: View {
    let name: String
    let tint: Color
    let diameter: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Image(systemName: name)
            .font(.system(size: diameter * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: diameter, height: diameter)
            .background {
                Circle().fill(LinearGradient(
                    colors: [tint.opacity(dark ? 0.3 : 0.16), tint.opacity(dark ? 0.18 : 0.24)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                Circle().strokeBorder(
                    LinearGradient(colors: [.white.opacity(dark ? 0.25 : 0.8), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75
                )
            }
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

    static func symbolName(_ status: ChargeStatus) -> String {
        switch status {
        case .onBattery: "battery.75percent"
        case .charging: "bolt.fill"
        case .pluggedInDraining, .fullyCharged, .chargeLimitReached, .pluggedInNotCharging: "powerplug.fill"
        }
    }

    static func tint(_ status: ChargeStatus) -> Color {
        switch status {
        case .charging, .fullyCharged, .chargeLimitReached: .green
        case .pluggedInDraining: .orange
        case .onBattery, .pluggedInNotCharging: .secondary
        }
    }

    static func text(_ status: ChargeStatus?) -> Text {
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

// MARK: - 电量、温度、功率

/// 三张读数卡片等高。卡片里只写数值，指标名放在悬停提示和无障碍标签里。
private struct MetricsRow: View {
    static let cardHeight: CGFloat = 92
    static let cardPadding = EdgeInsets(top: 9, leading: 12, bottom: 11, trailing: 11)

    let snapshot: BatterySnapshot
    /// 温度达到该值时显示“偏高”，即设置里的温度提醒阈值。
    let highTemperatureCelsius: Int
    let isAnimating: Bool
    let frozenTime: TimeInterval?

    var body: some View {
        HStack(spacing: 8) {
            BatteryLevelCard(snapshot: snapshot, isAnimating: isAnimating, frozenTime: frozenTime)
            TemperatureCard(celsius: snapshot.temperatureCelsius, highCelsius: highTemperatureCelsius)
            SystemPowerCard(milliwatts: snapshot.systemLoadMW)
        }
    }
}

/// 电量卡片画成一杯水：水位等于电量，水面是两层错开的波浪，面板打开时缓慢流动，充电时流得快一些。
/// 水是半透明的淡蓝，文字被水淹到的部分换成深品牌蓝（深色模式为亮蓝）。
private struct BatteryLevelCard: View {
    let snapshot: BatterySnapshot
    let isAnimating: Bool
    let frozenTime: TimeInterval?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: Double {
        Double(min(100, max(0, snapshot.percent ?? 0))) / 100
    }

    private var isCharging: Bool {
        if case .charging = ChargeStatus(snapshot) { true } else { false }
    }

    var body: some View {
        let isLive = frozenTime == nil && isAnimating && !reduceMotion
        let content = labels
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isLive)) { context in
            let time = frozenTime ?? (isLive ? context.date.timeIntervalSinceReferenceDate : 0)
            let phase = time * (isCharging ? 2.2 : 0.8)
            content
                .foregroundStyle(.primary)
                .overlay {
                    content
                        .foregroundStyle(underwaterText)
                        .mask(Wave(level: level, phase: phase, amplitude: 2.4))
                }
                .panelTile(padding: EdgeInsets()) {
                    water(phase: phase)
                }
        }
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: level)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Battery Level", bundle: .module))
        .accessibilityValue(Text(verbatim: DisplayFormat.percent(snapshot.percent)) + Text(verbatim: ", ") + helpText)
    }

    /// 数值和剩余时间，铺满整张卡片，用来和水位对齐。
    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            MetricValue(text: DisplayFormat.percent(snapshot.percent))
            MetricCaption {
                switch snapshot.remainingTime {
                case .untilEmpty(let minutes):
                    Image(systemName: "hourglass")
                    Text(verbatim: DisplayFormat.duration(minutes: minutes))
                case .untilFull(let minutes):
                    Image(systemName: "bolt.fill")
                    Text(verbatim: DisplayFormat.duration(minutes: minutes))
                case nil:
                    // 没有剩余时间时（接电未充电等）显示状态图标。
                    if let status = ChargeStatus(snapshot) {
                        Image(systemName: StatusLabel.symbolName(status))
                    }
                }
            }
            .opacity(0.8)
            Spacer(minLength: 0)
        }
        .padding(MetricsRow.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(height: MetricsRow.cardHeight)
    }

    @ViewBuilder
    private func water(phase: Double) -> some View {
        let dark = colorScheme == .dark
        ZStack {
            // 后一层浪颜色淡、相位错开，让水面有前后层次。
            Wave(level: level, phase: phase * 0.7 + 2.1, amplitude: 1.8)
                .fill(Color.brand.opacity(dark ? 0.12 : 0.08))
            // 上浅下深，透出卡片的玻璃底。
            Wave(level: level, phase: phase, amplitude: 2.4)
                .fill(LinearGradient(
                    colors: [Color.brand.opacity(dark ? 0.2 : 0.14), Color.brand.opacity(dark ? 0.3 : 0.24)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            Wave(level: level, phase: phase, amplitude: 2.4, surfaceOnly: true)
                .stroke(.white.opacity(dark ? 0.3 : 0.8), lineWidth: 1)
        }
    }

    /// 水下文字：浅色模式为深品牌蓝 `#13539A`，深色模式为亮蓝 `#8CC4FF`。
    private var underwaterText: Color {
        colorScheme == .dark ? Color(red: 0.55, green: 0.77, blue: 1) : Color(red: 0.075, green: 0.325, blue: 0.604)
    }

    private var helpText: Text {
        switch snapshot.remainingTime {
        case .untilEmpty(let minutes):
            Text("\(DisplayFormat.duration(minutes: minutes)) remaining", bundle: .module)
        case .untilFull(let minutes):
            Text("\(DisplayFormat.duration(minutes: minutes)) until full", bundle: .module)
        case nil:
            Text("Battery Level", bundle: .module)
        }
    }
}

/// 水面：`level` 为水位（0–1，从底部算起），`phase` 让波浪左右移动。`surfaceOnly` 为 true 时只画水面线。
/// 水位接近 0 或 1 时波幅收小，避免浪头超出卡片或在杯底露出空隙。
private struct Wave: Shape {
    var level: Double
    var phase: Double
    var amplitude: Double
    var surfaceOnly = false

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let damping = min(1, level * 12, (1 - level) * 12)
        let height = amplitude * damping
        let surface = rect.maxY - rect.height * level
        let wavelength = rect.width * 0.85
        var path = Path()
        let steps = 48
        for step in 0...steps {
            let x = rect.minX + rect.width * Double(step) / Double(steps)
            let y = surface + height * sin(x / wavelength * 2 * .pi + phase)
            if step == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        if !surfaceOnly {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// 温度卡片：数值下面是一条温度计刻度（15–50 °C），填充到当前温度，提醒阈值处有一道刻度。
/// 达到阈值时数值变橙色，图标旁标“偏高”。
private struct TemperatureCard: View {
    static let range: ClosedRange<Double> = 15...50

    let celsius: Double?
    let highCelsius: Int

    private var isHigh: Bool {
        guard let celsius else { return false }
        return celsius >= Double(highCelsius)
    }

    var body: some View {
        MetricCardLayout {
            MetricValue(text: DisplayFormat.celsius(celsius))
                .foregroundStyle(isHigh ? Color.orange : Color.primary)
        } caption: {
            Image(systemName: "thermometer.medium")
                .foregroundStyle(.red)
            if isHigh {
                Text("High", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .fixedSize()
            }
        } meter: {
            ThermometerTrack(
                fraction: celsius.map { Self.fraction($0) },
                thresholdFraction: Self.fraction(Double(highCelsius)),
                isHigh: isHigh
            )
        }
        .help(Text("Temperature", bundle: .module))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Temperature", bundle: .module))
        .accessibilityValue(Text(verbatim: DisplayFormat.celsius(celsius)))
    }

    private static func fraction(_ celsius: Double) -> Double {
        min(1, max(0, (celsius - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
}

/// 细胶囊轨道，从左填到当前温度，单色：正常为红色，达到提醒阈值为橙色；末端一颗白色圆点。
private struct ThermometerTrack: View {
    let fraction: Double?
    let thresholdFraction: Double
    let isHigh: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 5)
                if let fraction {
                    Capsule()
                        .fill(isHigh ? Color.orange : Color.red)
                        .frame(width: max(5, width * fraction), height: 5)
                    Circle()
                        .fill(.white)
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                        .offset(x: min(width - 9, max(0, width * fraction - 4.5)))
                }
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1.5, height: 9)
                    .offset(x: width * thresholdFraction - 0.75)
            }
            .frame(height: 9)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 10)
    }
}

/// 系统功率卡片：数值下面是一排由矮到高的能量格，按 0–60 W 点亮。
private struct SystemPowerCard: View {
    static let fullScaleMW = 60_000
    static let barCount = 10

    let milliwatts: Int?

    var body: some View {
        MetricCardLayout {
            MetricValue(text: DisplayFormat.watts(milliwatts: milliwatts))
        } caption: {
            Image(systemName: "cpu")
                .foregroundStyle(Color.systemPower)
        } meter: {
            EnergyBars(count: Self.barCount, lit: litBars)
        }
        .help(Text("Power", bundle: .module))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Power", bundle: .module))
        .accessibilityValue(Text(verbatim: DisplayFormat.watts(milliwatts: milliwatts)))
    }

    /// 有读数时至少点亮一格。
    private var litBars: Int {
        guard let milliwatts else { return 0 }
        let fraction = Double(max(0, milliwatts)) / Double(Self.fullScaleMW)
        return min(Self.barCount, max(1, Int((fraction * Double(Self.barCount)).rounded(.up))))
    }
}

private struct EnergyBars: View {
    let count: Int
    let lit: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? Color.systemPower : Color.primary.opacity(0.08))
                    .frame(height: 5 + 8 * Double(index) / Double(count - 1))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 13, alignment: .bottom)
    }
}

/// 温度、功率卡片的共同布局：大号数值，下面一行小图标说明，底部一个小图形。底色与其他块相同，指标颜色只用在图标和图形上。
private struct MetricCardLayout<Value: View, Caption: View, Meter: View>: View {
    @ViewBuilder let value: Value
    @ViewBuilder let caption: Caption
    @ViewBuilder let meter: Meter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            value
            MetricCaption { caption }
            Spacer(minLength: 0)
            meter
        }
        .padding(MetricsRow.cardPadding)
        .frame(height: MetricsRow.cardHeight)
        .panelTile(padding: EdgeInsets())
    }
}

/// 三张卡片的大号数值。
private struct MetricValue: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.65)
            .contentTransition(.numericText())
    }
}

/// 数值下面的一行：小图标，可带一段短文字。
private struct MetricCaption<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .minimumScaleFactor(0.75)
        .frame(height: 16)
    }
}

// MARK: - 充电上限

/// 系统充电上限：标题行右侧为开关，开启时下方为档位。AlDente 运行时禁用并说明原因。
private struct ChargeLimitTile: View {
    let control: ChargeLimitControl
    let onChange: @MainActor (ChargeLimitChange) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStaticControls) private var rendersStaticControls

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TintedSymbol(name: "bolt.shield.fill", tint: .green, diameter: 24)
                Text("System Charge Limit", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if rendersStaticControls {
                    StaticSwitch(isOn: control.isEnabled)
                        .opacity(control.isInteractive ? 1 : 0.5)
                } else {
                    Toggle(isOn: Binding(get: { control.isEnabled }, set: { onChange($0 ? .enable : .disable) })) {
                        Text("System Charge Limit", bundle: .module)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .disabled(!control.isInteractive)
                }
            }
            if control.isEnabled {
                LimitSegments(options: control.options, selection: control.percent) { onChange(.limit($0)) }
                    .disabled(!control.isInteractive)
                    .transition(PanelMotion.transition(reduceMotion: reduceMotion))
            }
            ChargeLimitNote(control: control)
                .font(.system(size: 11))
        }
        .panelTile()
    }
}

/// 渲染测试里代替系统开关的静态图形，尺寸接近 `.controlSize(.small)` 的开关。
private struct StaticSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.primary.opacity(0.15))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(1.5)
            }
    }
}

/// 铺满宽度的分段档位。系统 `.segmented` 在 macOS 上按内容宽度显示，不能铺满，所以用按钮画。
/// 选中块是一颗带亮边的胶囊，文字用品牌蓝，换档时用弹簧滑到新位置。
private struct LimitSegments: View {
    let options: [Int]
    let selection: Int?
    let onSelect: @MainActor (Int) -> Void
    @Namespace private var thumb
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { percent in
                segment(percent, isSelected: percent == selection)
            }
        }
        .padding(2.5)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), in: Capsule())
        .opacity(isEnabled ? 1 : 0.5)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: selection)
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.brand : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        SegmentThumb()
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SegmentThumb: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Capsule()
            .fill(LinearGradient(
                colors: dark ? [.white.opacity(0.3), .white.opacity(0.2)] : [.white, .white.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(Capsule().strokeBorder(.white.opacity(dark ? 0.25 : 1), lineWidth: 0.75))
            .shadow(color: .black.opacity(dark ? 0.3 : 0.12), radius: 3, y: 1.5)
    }
}

/// 其他充电控制应用运行或修改失败时的说明，面板和设置页共用。界面不点名具体应用。
struct ChargeLimitNote: View {
    let control: ChargeLimitControl

    var body: some View {
        if control.isBlocked {
            Text("Another charge control app is running. Quit it to change the charge limit here.", bundle: .module)
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

// MARK: - 电池健康和详细数据

/// 标题行右侧为健康状态；一行两列：系统最大容量、循环次数；下面是满充容量对比条和常驻的详细数据。
private struct HealthTile: View {
    let snapshot: BatterySnapshot
    let health: BatteryHealthInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TintedSymbol(name: "heart.fill", tint: .brand, diameter: 24)
                Text("Battery Health", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if let condition = health?.condition {
                    ConditionBadge(condition: condition)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                HealthValue(
                    label: Text("Maximum Capacity", bundle: .module),
                    value: DisplayFormat.percent(health?.systemMaximumCapacityPercent),
                    ring: health?.systemMaximumCapacityPercent.map { Double($0) / 100 }
                )
                .help(Text("Reported by macOS. Same as Battery Health in System Settings.", bundle: .module))
                ValueDivider()
                HealthValue(label: Text("Cycle Count", bundle: .module), value: DisplayFormat.number(snapshot.cycleCount))
            }
            .padding(.top, 12)
            FullChargeBar(
                fullCharge: snapshot.fullChargeCapacityMAh,
                design: snapshot.designCapacityMAh,
                ratio: snapshot.capacityRatio
            )
            .help(Text("Full charge capacity estimated by the battery, and its percentage of the design capacity.", bundle: .module))
            .padding(.top, 14)
            HairlineDivider()
                .padding(.top, 12)
            DetailsSection(snapshot: snapshot)
        }
        .panelTile(padding: EdgeInsets(top: 12, leading: 14, bottom: 0, trailing: 14))
    }
}

/// 健康状态胶囊：`"Good"` 为绿色本地化文字，其他值原样显示英文原文，用橙色。
private struct ConditionBadge: View {
    let condition: BatteryHealthCondition

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            text
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
    }

    private var tint: Color {
        if case .good = condition { .green } else { .orange }
    }

    private var text: Text {
        switch condition {
        case .good: Text("Good", bundle: .module)
        case .other(let value): Text(verbatim: value)
        }
    }
}

private struct HealthValue: View {
    let label: Text
    let value: String
    var unit: String?
    /// 数值前的小圆环，0–1。
    var ring: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                if let ring {
                    CapacityRing(fraction: ring)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .padding(.trailing, 3)
                }
                Text(verbatim: value)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let unit {
                    Text(verbatim: unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .minimumScaleFactor(0.75)
            label
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 系统最大容量的小圆环：品牌蓝从顶部顺时针画到当前比例。
private struct CapacityRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Color.brand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }
}

/// 满充容量和设计容量的对比：上面一行写两个容量和满充 / 设计，下面的条长度为满充 / 设计。
private struct FullChargeBar: View {
    let fullCharge: Int?
    let design: Int?
    let ratio: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Full Charge Capacity", bundle: .module)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: DisplayFormat.number(fullCharge))
                    .fontWeight(.medium)
                if let design {
                    Text(verbatim: "/ \(design) mAh")
                        .foregroundStyle(.secondary)
                } else if fullCharge != nil {
                    Text(verbatim: "mAh")
                        .foregroundStyle(.secondary)
                }
                if let ratio {
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    Text(verbatim: DisplayFormat.percent(ratio: ratio))
                        .fontWeight(.medium)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(Color.brand.opacity(0.6))
                        .frame(width: proxy.size.width * min(1, max(0, ratio ?? 0)))
                }
            }
            .frame(height: 4)
        }
    }
}

/// 健康读数之间的竖线。
private struct ValueDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 30)
            .padding(.trailing, 10)
            .padding(.top, 3)
    }
}

private struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

/// 详细数据始终显示；电压、电流只保留充电器输入端，接电时显示。
private struct DetailsSection: View {
    let snapshot: BatterySnapshot

    private var isExternalPower: Bool {
        snapshot.isExternalPower == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)

            VStack(spacing: 7) {
                ValueRow(Text("Battery Power", bundle: .module), value: DisplayFormat.signedWatts(milliwatts: snapshot.batteryPowerMW))
                if isExternalPower {
                    HairlineDivider()
                    ValueRow(Text("Charger", bundle: .module), value: adapter)
                        .help(Text(verbatim: adapterDescription))
                    ValueRow(Text("Input Voltage · Current", bundle: .module), value: chargerInput)
                }
            }
            .padding(.bottom, 12)
        }
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
    let onOpenSettings: @MainActor () -> Void
    let onQuit: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let lowPowerModeEnabled {
                LowPowerModeBadge(isEnabled: lowPowerModeEnabled)
            }
            Spacer(minLength: 0)
            actionButton("macwindow", title: Text("Open Main Window", bundle: .module), action: onOpenMainWindow)
            actionButton("gearshape", title: Text("Settings", bundle: .module), action: onOpenSettings)
            actionButton("power", title: Text("Quit", bundle: .module), action: onQuit)
        }
    }

    private func actionButton(_ symbol: String, title: Text, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 14, height: 14)
        }
        .panelGlassButtonStyle()
        .controlSize(.large)
        .buttonBorderShape(.circle)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// 低电量模式状态胶囊：开启时黄色（与系统电池图标一致），关闭时与玻璃按钮同样的底色、次要色。宽度不够时只显示图标和开关状态。
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
                .foregroundStyle(isEnabled ? Color.yellow : Color.secondary)
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
                Capsule().fill(PanelTileStyle.fillGradient(colorScheme))
            }
            Capsule().strokeBorder(PanelTileStyle.rim(colorScheme), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: PanelTileStyle.shadow(colorScheme), radius: 6, y: 2)
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
enum PanelPreviewData {
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
            onOpenSettings: {},
            onQuit: {}
        )
        .panelGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .panelOutline(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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

/// 电池流带很细，数值写在流带外，用来检查数值是否超出图顶或互相重叠。
#Preview("Plugged In, Slightly Draining") {
    PanelPreview(reading: .battery(PanelPreviewData.snapshot(
        percent: 72,
        batteryPowerMW: -3000,
        powerInMW: 30000,
        systemLoadMW: 33000,
        amperageMA: -250
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
