import SwiftUI

/// 主窗口的内容：历史曲线、通知、设置三页（待实现）。
public struct MainWindowRootView: View {
    public init() {}

    public var body: some View {
        Text("History, notifications and settings will appear here.", bundle: .module)
            .foregroundStyle(.secondary)
            .frame(minWidth: 720, minHeight: 480)
    }
}
