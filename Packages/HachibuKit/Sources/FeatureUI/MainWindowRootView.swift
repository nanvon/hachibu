import HistoryStore
import SwiftUI

/// 主窗口的内容：侧栏切换历史曲线、通知、设置三页。窗口行为由 App 层的 MainWindowController 负责。
public struct MainWindowRootView: View {
    private let history: HistoryModel
    @State private var selection: MainWindowPage? = .history

    public init(history: HistoryModel) {
        self.history = history
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
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            let page = selection ?? .history
            switch page {
            case .history:
                HistoryPage(model: history)
            case .notifications, .settings:
                PlaceholderPage(page: page)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
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

/// 侧栏底部：“自 {日期} 开始记录 · 已记录 {N} 天”。
private struct RecordingSummaryView: View {
    let summary: RecordingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let firstDay = HistoryChartBuilder.startOfDay(summary.firstDay) {
                Text("Recording since \(firstDay.formatted(date: .abbreviated, time: .omitted))", bundle: .module)
            }
            Text("\(summary.dayCount) days recorded", bundle: .module)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 通知、设置页尚未实现。
private struct PlaceholderPage: View {
    let page: MainWindowPage

    var body: some View {
        ContentUnavailableView {
            Label {
                page.title
            } icon: {
                Image(systemName: page.systemImage)
            }
        } description: {
            Text("Not available yet.", bundle: .module)
        }
    }
}
