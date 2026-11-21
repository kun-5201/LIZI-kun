import SwiftUI

/// 形态下拉面板（r26，用户 22:35 设计图：点顶栏「形态」在当前歌曲画面上
/// 弹深色两列下拉面板就地切，不再跳单独的选择形态界面）。
///
/// 旧的全屏选择器（NavigationStack + List + 「发行版 / 全部目录」分段 +
/// 搜索）已撤：r26 删无文件条目后两个分段内容完全一致（都只剩 86 项），
/// 设计图里也没有搜索框/分段，全部拿掉，只剩两列名字。
/// - 内容 = `StageCatalog.menuList(includeClassic: true, releaseOnly: true)`：
///   classic（传统播放器）+ 86 个有文件形态，全部可播放；顺序沿用壳版
///   displayOrder（classic、504、519 置顶，其余倒序），与旧选择器一致。
/// - 样式对照壳版 `.smenu`：深色面板（外壳见 StageFloatPanel）、两列网格、
///   行高 44、只显示名字、当前行白底 14% 高亮。点一行即切（classic 回
///   播放页），面板随即收起；点面板外面收起（StageView 的点按捕捉层）。
/// - 歌不停：切形态只调 bridge.load，不动播放状态。
struct StagePickerView: View {
    @ObservedObject var bridge: StageBridge
    /// 选形态后的回调（StageView 接：classic 回播放页，其余调 bridge.load，
    /// 并收起面板）。
    var onSelect: (StageForm) -> Void

    private var listed: [StageForm] {
        StageCatalog.menuList(includeClassic: true, releaseOnly: true)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(listed) { form in
                    Button(action: { onSelect(form) }) {
                        Text(form.name)
                            .font(.system(size: 15))
                            .foregroundStyle(
                                currentFormId == form.formId
                                    ? .white
                                    : .white.opacity(0.78)
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 44)
                            .padding(.horizontal, 9)
                            .background(
                                currentFormId == form.formId
                                    ? Color.white.opacity(0.14)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        form.name + (currentFormId == form.formId ? "，当前形态" : "")
                    )
                }
            }
            .padding(8)
        }
    }

    private var currentFormId: String { bridge.currentForm.formId }
}
