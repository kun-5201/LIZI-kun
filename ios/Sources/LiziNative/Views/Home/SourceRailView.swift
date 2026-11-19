import SwiftUI

/// 来源切换 + 非每日推荐来源的内容区。
///
/// - P1 用横向 chips 简化（壳版的球面滚轮 / Option Wheel 是 P3 打磨项）。
/// - 每日推荐的内容就是跑马带（由 HomeView 直接放 chips 下方）；
///   其余四种来源在 P1 只有诚实空态——原生桥暂无对应列表接口，
///   不编假数据，P2 按平台逐个接：
///   - 精选：各平台精选接口待接。
///   - 喜欢 rail：只存了 id（PlaybackStore 的 likedTrackIds），
///     曲目详情待 P2 补全；P1 只报已喜欢的首数。
///   - 我收藏的歌单：收藏歌单列表接口待接。
///   - 电台：原生桥暂无电台接口，P2 先核查各平台官方接口再接。
struct SourceChipsView: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HomeViewModel.Source.allCases, id: \.self) { source in
                    let selected = source == viewModel.selectedSource
                    Button(action: { viewModel.selectSource(source) }) {
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
            .padding(.horizontal, 16)
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

/// 本地音乐区占位：P4 的活（文件导入 + 列表 + 开关）。
/// P1 只留一个标明「未上线」的行，不放假列表、不放假开关。
struct LocalMusicPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本地音乐")
                .font(.liziDisplay(size: LiziTokens.size20))
                .foregroundColor(LiziTokens.ink)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundColor(LiziTokens.ink3)
                Text("P4 接入文件导入与列表")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(LiziTokens.ink3)
            }
            .padding(16)
            .background(LiziTokens.paper2)
            .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius14))
        }
        .padding(.horizontal, 16)
        .opacity(0.7)
    }
}
