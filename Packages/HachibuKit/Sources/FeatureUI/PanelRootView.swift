import SwiftUI

/// 菜单栏面板的内容。窗口定位、关闭、焦点由 App 层的 PanelController 负责。
public struct PanelRootView: View {
    private let onOpenMainWindow: @MainActor () -> Void
    private let onQuit: @MainActor () -> Void

    public init(
        onOpenMainWindow: @escaping @MainActor () -> Void,
        onQuit: @escaping @MainActor () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Hachibu")
                .font(.title2.weight(.semibold))
            Text("Battery data will appear here.", bundle: .module)
                .foregroundStyle(.secondary)
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
