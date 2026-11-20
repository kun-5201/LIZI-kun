import SwiftUI

/// 舞台页两个就地浮层的共用外壳（r26，用户 22:35 设计图 + 22:36 齿轮同款要求）。
///
/// 样式对照壳版 `.smenu` / `.spnl`（同一套）：磨砂半透明面板（r28，用户「都做成透明的」：
/// `.ultraThinMaterial` + 深色 0.28 遮罩，舞台画面透出、白字仍可读）、圆角 18、细白描边、
/// 大阴影；形态下拉与齿轮面板共用这一只，两处视觉一致。
/// 内容各自是 StagePickerView / StageSettingsView；位置由 StageView 的
/// floatingPanel 定（右上锚定、顶行下方 10pt）。
struct StageFloatPanel<Content: View>: View {
    let width: CGFloat
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(width: width)
            .frame(maxHeight: maxHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.10).opacity(0.28))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 26, x: 0, y: 12)
            .environment(\.colorScheme, .dark)
    }
}
