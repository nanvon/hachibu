import HistoryStore
import SwiftUI

/// 主窗口的内容：侧栏切换历史曲线、通知、设置三页。窗口行为由 App 层的 MainWindowController 负责。
public struct MainWindowRootView: View {
    private let history: HistoryModel
    private let settings: AppSettings
    private let alerts: AlertMonitor
    private let onExportDiagnostics: @MainActor () async -> Void
    private let onCheckForUpdates: (@MainActor () -> Void)?
    @State private var selection: MainWindowPage? = .history

    /// `onExportDiagnostics` 由 App 层选择保存位置并写文件，完成后返回。
    /// `onCheckForUpdates` 为 nil 时（更新器未启用）设置页不显示“检查更新”。
    public init(
        history: HistoryModel,
        settings: AppSettings,
        alerts: AlertMonitor,
        onExportDiagnostics: @escaping @MainActor () async -> Void,
        onCheckForUpdates: (@MainActor () -> Void)?
    ) {
        self.history = history
        self.settings = settings
        self.alerts = alerts
        self.onExportDiagnostics = onExportDiagnostics
        self.onCheckForUpdates = onCheckForUpdates
    }

    public var body: some View {
        NavigationSplitView {
            List(MainWindowPage.allCases, selection: $selection) { page in
                Label {
                    page.title
                } icon: {
                    Image(systemName: page.systemImage)
                }
                .tag(page)
            }
            .safeAreaInset(edge: .bottom) {
                if let summary = history.summary {
                    RecordingSummaryView(summary: summary)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 280)
        } detail: {
            let page = selection ?? .history
            Group {
                switch page {
                case .history:
                    HistoryPage(model: history)
                case .notifications:
                    NotificationsPage(settings: settings, alerts: alerts)
                case .settings:
                    SettingsPage(
                        settings: settings,
                        onExportDiagnostics: onExportDiagnostics,
                        onCheckForUpdates: onCheckForUpdates
                    )
                }
            }
            // 标题由 sceneBridgingOptions 显示在窗口工具栏，页面内不再手写标题。
            .navigationTitle(page.title)
        }
        .frame(minWidth: 960, minHeight: 660)
        // 与菜单栏面板一致，不显示控件的焦点环。
        .focusEffectDisabled()
    }
}

enum MainWindowPage: CaseIterable, Identifiable, Hashable {
    case history, notifications, settings

    var id: Self { self }

    var title: Text {
        switch self {
        case .history: Text("History", bundle: .module)
        case .notifications: Text("Notifications", bundle: .module)
        case .settings: Text("Settings", bundle: .module)
        }
    }

    var systemImage: String {
        switch self {
        case .history: "chart.xyaxis.line"
        case .notifications: "bell"
        case .settings: "gearshape"
        }
    }
}

/// 侧栏底部的记录概况：“已记录 {N} 天”，下面一行“自 {日期} 开始记录”。
private struct RecordingSummaryView: View {
    let summary: RecordingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(summary.dayCount) days recorded", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
            if let firstDay = HistoryChartBuilder.startOfDay(summary.firstDay) {
                Text("Recording since \(firstDay.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}
