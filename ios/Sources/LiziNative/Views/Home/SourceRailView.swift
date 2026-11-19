import SwiftUI

/// 来源切换 + 非每日推荐来源的内容区。
///
/// - P1 用横向 chips 简化（壳版的球面滚轮 / Option Wheel 是 P3 打磨项）。
///   5 个来源一排 pills，点哪个切哪个（壳版那一排移植过来）：
///   每日推荐 → 精选 → 喜欢 → 我收藏的歌单 → 电台，顺序 = Source.allCases。
/// - r23 已删长按上下滑切换来源（r22j 第二件）：长按 0.5s +
///   DragGesture(minimumDistance: 0) 经 highPriorityGesture 挂在 chips 行上，
///   和首页竖向 ScrollView、下面 3D 带子的 UIKit pan（StripTouchView）抢同一根
///   竖向触摸——按住 0.5 秒后拖动手势把触摸抢走、页面滚不动；手指滑出这行或
///   ScrollView 抢回触摸时 sequenced 手势走不到干净的 .second 结束，tooltip
///   清不掉、highPriorityGesture 继续吃点按和滚动，看起来就是卡死。删掉长按
///   手势就是根治，不要再加回来。注释里旧写的「横向快滑 >10pt 让长按失败」
///   代码里根本没有实现，不要信。
/// - 每日推荐的内容就是跑马带（环的平面态，在面板里）；
///   其余四种来源是 rail 行（点卡 / 点展开进 RailDetailView，P2 已接，
///   各平台接口见 RailsBridge；没有接口的平台诚实空态，不编假数据）。
struct SourceChipsView: View {
    @ObservedObject var viewModel: HomeViewModel

    /// 登录提示（r23 集成）：切到需要登录的来源时弹提示，不切过去。
    @State private var loginPrompt: LoginPrompt?
    @State private var loginTarget: LoginSheetTarget?

    private var sources: [HomeViewModel.Source] { HomeViewModel.Source.allCases }

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
                        let selected = source == viewModel.selectedSource
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
        }
        // r23 集成：登录提示 alert + 「去登录」 sheet（来源 chips 切换用）。
        .loginRequiredAlert(prompt: $loginPrompt, loginTarget: $loginTarget)
        .sheet(item: $loginTarget) { LoginSheetView(platform: $0.platform) }
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
