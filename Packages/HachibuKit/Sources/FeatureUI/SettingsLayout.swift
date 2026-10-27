import AppKit
import SwiftUI

// 通知页、设置页的两栏布局：左栏是分组标题和说明，右栏是一块浅色面板，里面一行一项，控件用系统控件。
// 样式见 docs/v1技术设计.md 19.3。

/// 页面内容的外边距，和历史页一致。
struct SettingsColumns<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一个分组：左栏标题、说明和附加内容（如通知预览），右栏面板。分组之间由页面插入 `SettingsGroupDivider`。
struct SettingsGroup<Aside: View, Panel: View>: View {
    let title: Text
    let description: Text?
    let aside: Aside
    let panel: Panel

    static var labelColumnWidth: CGFloat { 260 }

    init(
        _ title: Text,
        description: Text? = nil,
        @ViewBuilder aside: () -> Aside,
        @ViewBuilder panel: () -> Panel
    ) {
        self.title = title
        self.description = description
        self.aside = aside()
        self.panel = panel()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                title
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let description {
                    description
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                aside
                    .padding(.top, 6)
            }
            // 标题第一行和面板第一行对齐。
            .padding(.top, 10)
            .frame(width: Self.labelColumnWidth, alignment: .leading)

            SettingsPanel {
                panel
            }
        }
        .padding(.vertical, 22)
    }
}

extension SettingsGroup where Aside == EmptyView {
    init(_ title: Text, description: Text? = nil, @ViewBuilder panel: () -> Panel) {
        self.init(title, description: description, aside: { EmptyView() }, panel: panel)
    }
}

/// 分组之间的细分隔线。
struct SettingsGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}

/// 右栏面板：一块浅色圆角底，不加边框和阴影。
private struct SettingsPanel<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }
}

/// 面板里的一行：左边标题（可带一行说明），右边控件或读数。
struct SettingsRow<Control: View>: View {
    let title: Text
    let subtitle: Text?
    let control: Control

    init(_ title: Text, subtitle: Text? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    subtitle
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control
                .font(.system(size: 13))
                .monospacedDigit()
        }
        .frame(minHeight: 40)
        .padding(.vertical, 5)
    }
}

/// 面板内行与行之间的分隔线。
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}

/// 面板底部右对齐的按钮行。
struct SettingsPanelFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            content
        }
        .padding(.vertical, 10)
    }
}

/// 面板里的说明或错误，单独一行，可换行。
struct SettingsNote: View {
    let text: Text
    var isError = false

    var body: some View {
        text
            .font(.system(size: 11.5))
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
    }
}

/// 状态胶囊：已允许、监测中等。`tint` 为 nil 时为中性灰。
struct StatusPill: View {
    let text: Text
    var tint: Color?

    var body: some View {
        text
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// 通知预览，放在提醒分组的左栏，显示这条提醒会是什么样子。
struct NotificationPreview: View {
    let title: Text
    let message: Text
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 12, weight: .semibold))
                message
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 系统控件

/// 系统开关；渲染测试里换成静态图形。
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let label: Text
    @Environment(\.rendersStaticControls) private var rendersStaticControls
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if rendersStaticControls {
            StaticSwitch(isOn: isOn)
                .opacity(isEnabled ? 1 : 0.5)
        } else {
            Toggle(isOn: $isOn) { label }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}

/// 数值加系统步进器；渲染测试里步进器换成静态图形。
struct SettingsStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let text: String
    let label: Text
    @Environment(\.rendersStaticControls) private var rendersStaticControls
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: text)
                .monospacedDigit()
                .foregroundStyle(isEnabled ? .primary : .secondary)
            if rendersStaticControls {
                StaticStepper()
                    .opacity(isEnabled ? 1 : 0.5)
            } else {
                Stepper(value: $value, in: range) { label }
                    .labelsHidden()
            }
        }
    }
}

/// 系统弹出菜单；渲染测试里换成静态图形。
struct SettingsMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> Text
    let label: Text
    @Environment(\.rendersStaticControls) private var rendersStaticControls

    var body: some View {
        if rendersStaticControls {
            HStack(spacing: 6) {
                title(selection)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .modifier(StaticControlChrome())
        } else {
            Picker(selection: $selection) {
                ForEach(options, id: \.self) { option in
                    title(option).tag(option)
                }
            } label: {
                label
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// 系统链接；渲染测试里换成同色文字。
struct SettingsLink: View {
    let destination: URL
    let text: String
    @Environment(\.rendersStaticControls) private var rendersStaticControls

    var body: some View {
        if rendersStaticControls {
            Text(verbatim: text)
                .foregroundStyle(Color.accentColor)
        } else {
            Link(destination: destination) {
                Text(verbatim: text)
            }
        }
    }
}

extension View {
    /// 系统按钮；渲染测试里换成静态边框。
    func settingsButtonStyle() -> some View {
        modifier(SettingsButtonStyleModifier())
    }
}

private struct SettingsButtonStyleModifier: ViewModifier {
    @Environment(\.rendersStaticControls) private var rendersStaticControls

    func body(content: Content) -> some View {
        if rendersStaticControls {
            content.buttonStyle(StaticButtonStyle())
        } else {
            content
        }
    }
}

/// 渲染测试里代替系统按钮的静态图形，尺寸接近 `.controlSize(.regular)` 的按钮。
private struct StaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StaticControlChrome())
    }
}

private struct StaticControlChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .frame(minHeight: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.white)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.16), lineWidth: 0.5)
            }
    }
}

/// 渲染测试里代替系统步进器的静态图形。
private struct StaticStepper: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "chevron.up")
            Image(systemName: "chevron.down")
        }
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 13, height: 21)
        .modifier(StaticControlChrome())
    }
}
