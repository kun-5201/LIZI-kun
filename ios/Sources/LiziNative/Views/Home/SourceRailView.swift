import SwiftUI
import UIKit

/// 来源切换 + 非每日推荐来源的内容区。
///
/// - P1 用横向 chips 简化（壳版的球面滚轮 / Option Wheel 是 P3 打磨项）。
///   r22j 第二件：chips 行上加「长按上下滑切换来源」（用户新要的交互，
///   壳版第 14 轮删掉的长按选歌单不恢复——那是另一个功能）：
///   长按 0.5s 进入切换模式，上下滑在 5 个来源之间切（上滑 = 下一个，
///   下滑 = 上一个），松手确认；只动不按不切，两端夹住不回卷。
///   顺序 = Source.allCases：每日推荐 → 精选 → 喜欢 → 我收藏的歌单 → 电台，
///   步长 44pt。手势冲突见 switchGesture 注释。
/// - 每日推荐的内容就是跑马带（环的平面态，在面板里）；
///   其余四种来源是 rail 行（点卡 / 点展开进 RailDetailView，P2 已接，
///   各平台接口见 RailsBridge；没有接口的平台诚实空态，不编假数据）。
struct SourceChipsView: View {
    @ObservedObject var viewModel: HomeViewModel

    /// 长按切换模式的状态（r22j 第二件）：起点下标 + 正在预览的来源。
    /// 预览只改 chips 的高亮，松手才调 selectSource 提交。
    @State private var switchStart: Int? = nil
    @State private var switchPreview: HomeViewModel.Source? = nil
    /// 登录提示（r23 集成）：切到需要登录的来源时弹提示，不切过去。
    @State private var loginPrompt: LoginPrompt?
    @State private var loginTarget: LoginSheetTarget?

    /// 长按进入切换模式的按住时长（0.5s；短于一次点按不会误触发）。
    private static let longPressDuration: Double = 0.5
    /// 每滑过一个来源的纵向距离（44pt，拇指一步一切一个来源）。
    private static let switchStep: CGFloat = 44

    private var sources: [HomeViewModel.Source] { HomeViewModel.Source.allCases }

    /// 切换中正在预览的来源（没在切换时就是当前来源）。
    private var shownSource: HomeViewModel.Source { switchPreview ?? viewModel.selectedSource }

    /// 带登录墙的来源切换（r23 集成）：liked / playlists 未登录时弹提示，
    /// 不切过去；其余来源（每日推荐/精选/电台）直接切（LoginGate 判定表里本来就是 nil）。
    private func selectSourceGated(_ source: HomeViewModel.Source) {
        if let kind = source.railKind,
           let p = LoginGate.prompt(forRail: kind, platform: viewModel.selectedPlatform) {
            loginPrompt = p
        } else {
            viewModel.selectSource(source)
        }
    }

    /// r22j：chips 住在铺色面板里（见 HomeView），横向留白由面板的 10pt
    /// 内边距给，这里不再另加 16（壳版来源滚轮也是浮在面板里、不另占 gutter）。
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources, id: \.self) { source in
                        let selected = source == shownSource
                        Button(action: { selectSourceGated(source) }) {
                            Label(source.title(for: viewModel.selectedPlatform), systemImage: source.icon)
                                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                                .foregroundColor(selected ? .white : LiziTokens.ink2)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(selected ? LiziTokens.ink : LiziTokens.paper2)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().stroke(LiziTokens.rule, lineWidth: selected ? 0 : 1)
                                )
                        }
                        .accessibilityLabel("来源：\(source.title(for: viewModel.selectedPlatform))")
                    }
                }
            }
            // 隐藏手势的唯一可见提示（长按本身没有按钮可点）。
            Text("长按上下滑切换来源")
                .font(.liziBody(size: 11))
                .foregroundColor(LiziTokens.ink3)
        }
        .overlay(alignment: .center) {
            if let preview = switchPreview {
                Text("松手切换到「\(preview.title(for: viewModel.selectedPlatform))」")
                    .font(.liziBody(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(LiziTokens.ink)
                    .clipShape(Capsule())
            }
        }
        .highPriorityGesture(switchGesture)
        // r23 集成：登录提示 alert + 「去登录」 sheet（来源 chips 切换用）。
        .loginRequiredAlert(prompt: $loginPrompt, loginTarget: $loginTarget)
        .sheet(item: $loginTarget) { LoginSheetView(platform: $0.platform) }
    }

    /// 长按 + 上下滑切换来源（r22j 第二件）。
    ///
    /// - 形态：`LongPressGesture(0.5s).sequenced(before: DragGesture(0))`：
    ///   按住 0.5s 才进模式，之后的手指纵向移动按 44pt 一档换预览来源，
    ///   松手提交（调已有的 `selectSource`，不另写切换逻辑）。
    /// - 不和已有手势撞：
    ///   1. 3D 环的上滑展开：环的手势只认跑马带（`StripTouchView`，
    ///      HomeCoverRingView.swift 内），本手势只挂在 chips 行上，
    ///      两块区域不重叠，手指落点决定归属。
    ///   2. 页面竖滑：进模式要先按住 0.5s 不动；手指一动就滚页面时
    ///      长按还没成功就失败了，页面照常滚；只有按住 0.5s 后再滑，
    ///      手势才接管、页面不滚。
    ///   3. Hero 滑动切歌：Hero 是面板外的另一块视图，横向拖动，
    ///      与本手势（chips 行、纵向）无交集。
    ///   4. chips 横向滚动：横向快滑（>10pt）让长按直接失败，chips 照常滚；
    ///      进模式后的横向移动只看纵向分量，预览不动。
    ///   5. chips 点按：点按（<0.5s）长按不触发，照常切来源；
    ///      `highPriorityGesture` 让已识别的长按取消按钮点按——长按后松手
    ///      不会再误触一次点按切到按住的那张 chip。
    /// - 只动不按不切：长按后没滑就松手，预览 = 当前来源，提交时判定
    ///   相同直接返回。两端夹住不回卷（在每日推荐时再下滑、到电台时再上滑都到头）。
    private var switchGesture: some Gesture {
        LongPressGesture(minimumDuration: Self.longPressDuration)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first(true):
                    // 长按成功：进入切换模式，起点 = 当前来源。
                    if switchStart == nil {
                        switchStart = sources.firstIndex(of: viewModel.selectedSource) ?? 0
                        switchPreview = viewModel.selectedSource
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                case .second(true, let drag):
                    guard let start = switchStart, let drag = drag else { return }
                    // 上滑（dy 为负）= 下一个来源，下滑 = 上一个；步长 44pt。
                    let steps = Int(-drag.translation.height / Self.switchStep)
                    let idx = min(max(start + steps, 0), sources.count - 1)
                    switchPreview = sources[idx]
                default:
                    break
                }
            }
            .onEnded { value in
                defer { switchStart = nil; switchPreview = nil }
                guard case .second(true, let drag) = value, let drag = drag else { return }
                let start = switchStart ?? sources.firstIndex(of: viewModel.selectedSource) ?? 0
                let steps = Int(-drag.translation.height / Self.switchStep)
                let idx = min(max(start + steps, 0), sources.count - 1)
                let target = sources[idx]
                guard target != viewModel.selectedSource else { return }
                selectSourceGated(target)
            }
    }
}

/// 非每日推荐来源的空态卡（诚实说明为什么空 + 还差什么）。
struct SourceEmptyView: View {
    let source: HomeViewModel.Source
    let platformName: String
    let likedCount: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: source.icon)
                .font(.system(size: 20))
                .foregroundColor(LiziTokens.ink3)
            Text(source.title)
                .font(.liziBody(size: LiziTokens.size14, weight: .semibold))
                .foregroundColor(LiziTokens.ink)
            Text(reason)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
        .padding(.horizontal, 24)
        .background(LiziTokens.paper2)
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
        .padding(.horizontal, 16)
    }

    private var reason: String {
        switch source {
        case .daily:
            return ""
        case .featured:
            return "精选尚未接入原生桥：各平台精选接口在 P2 按平台逐个接，不编假数据。"
        case .liked:
            if likedCount > 0 {
                return "已喜欢 \(likedCount) 首，曲目详情待 P2 补全（当前只存了 id）。"
            }
            return "还没有喜欢的歌曲，在播放页点星标收藏。"
        case .playlists:
            return "我收藏的歌单尚未接入：收藏歌单列表接口在 P2 接。"
        case .radio:
            return "电台尚未接入：原生桥暂无电台接口，P2 先核查各平台官方接口再接。"
        }
    }
}

/// 本地音乐区占位已删（r22 模板 v2）：本地音乐由 `LocalMusicView.swift`
/// 的 `LocalMusicSectionView` 真做（文件夹卡片 + 文件列表 + 导入按钮），
/// HomeView 直接挂它，不再挂占位。
