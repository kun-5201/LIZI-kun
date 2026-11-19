import SwiftUI

/// 首页（大厅）：顶栏 + Hero 大卡 + 平台条 + 来源 chips + 每日推荐跑马带。
///
/// 布局自上而下（照抄壳版大厅结构，P1 只做这几块）：
/// 1. 顶栏：品牌「LIZI」+ kun 斜体字（文字排版，不要图片）；
///    右侧搜索（进搜索页）与设置齿轮。
/// 2. Hero 大卡（HeroCardView）。
/// 3. 平台条（PlatformStripView）：7 家平台横排，点按切台。
/// 4. 来源 chips（SourceChipsView）：每日推荐 / 精选 / 喜欢（标题按平台取真名） /
///    我收藏的歌单 / 电台——P1 用横向 chips，球面滚轮是 P3 打磨项。
/// 4.5 3D 封面环（HomeCoverRingView，r20）：壳版首页下半区 `.ringsec` 的原生版，
///    位置与壳版一致——Hero 大卡 → 平台条 → 来源 chips 之后、每日推荐 / rails 之前。
///    内容是播放队列（非空时）或每日推荐（队列为空时），两份都空时不显示。
/// 5. 内容区：每日推荐 = 跑马带；其余来源 = rail 行（P2：标题 + 横向卡片 +
///    点开展开，见 RailRowView；点卡片 / 点展开都进 RailDetailView）。
/// 6. 本地音乐区占位（P4 的活，只留行，不放假列表）。
///
/// 设置齿轮的决定（P3-C）：点按进设置页（AppNavigation.settings），
/// P1 的空态提示横幅已撤掉。
struct HomeView: View {
    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        GeometryReader { outer in
            // r20 顶栏修复：topBar 原来是 ScrollView 里的第一行，往下滚就滚出
            // 屏幕——QQ/酷狗每日推荐有真内容可翻，用户一翻搜索/设置就不见了；
            // 其它平台每日为空、没东西可翻，所以显得只有 QQ/酷狗出问题。
            // 根因与平台切换逻辑无关（selectPlatform 对 7 家同一套），所以
            // 不修 ViewModel、不加平台分支：只把 topBar 固定在滚动区之外，
            // 7 个平台同一套固定顶栏。logo 那几行不动（工人 J 在改）。
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HeroCardView(
                            width: outer.size.width - 32,
                            viewHeight: outer.size.height,
                            viewModel: viewModel
                        )
                        .padding(.horizontal, 16)

                        PlatformStripView(viewModel: viewModel)

                        SourceChipsView(viewModel: viewModel)

                        // r20：首页 3D 封面环（壳版位置：Hero → 平台条 → 来源 chips
                        // 之后、每日推荐之前；见 HomeCoverRingView 文件头证据）。
                        // 独立区块：只加这一处接入点，不动 hero / 平台条 /
                        // 来源 chips / 每日推荐 / rails / 本地音乐任何一行。
                        // 尺寸档按实测屏宽分（topInset 不参与分档，见 PlayerTokens）。
                        HomeCoverRingView(
                            dailyTracks: viewModel.daily.map { $0.track },
                            tier: PlayerTokens.sizeTier(for: outer.size, topInset: outer.safeAreaInsets.top)
                        )
                        .padding(.horizontal, 16)

                        if viewModel.selectedSource == .daily {
                            DailyMarqueeView(
                                tracks: viewModel.daily,
                                isLoading: viewModel.isLoadingDaily,
                                emptyReason: viewModel.dailyEmptyReason,
                                speedPxPerSecond: viewModel.marqSpeedPxPerSecond,
                                onPlay: { index in
                                    // 点一首直接播：整份每日推荐进队列，从该首起播。
                                    playback.setQueue(viewModel.daily.map { $0.track }, startAt: index)
                                }
                            )
                            .padding(.horizontal, 16)
                        } else if let kind = viewModel.selectedSource.railKind {
                            // P2：四条 rails 各一行（标题 + 横向卡片 + 点开展开）。
                            // 点卡片进详情（RailDetailView），不在行里直接播。
                            // 喜欢 rail 的标题按当前平台取真名（displayTitle），
                            // 与来源 chip、空态文案、详情页标题同一份事实来源。
                            RailRowView(
                                kind: kind,
                                platform: viewModel.selectedPlatform,
                                result: viewModel.rails[kind],
                                isLoading: viewModel.railLoading[kind] ?? false,
                                onExpand: { viewModel.openRail(kind) },
                                onRetry: {
                                    Task { await viewModel.loadRail(kind) }
                                }
                            )
                            .padding(.horizontal, 16)
                            if viewModel.selectedSource == .playlists {
                                MyAlbumsEntryView()
                                    .padding(.horizontal, 16)
                            }
                        }

                        LocalMusicPlaceholderView()
                    }
                    // 原来 VStack 的 .padding(.top, 8) 是顶栏上方的 8pt；顶栏移出后
                    // 这里改成 20pt：48（顶栏区 8+40）+ 20 = 原来 Hero 顶到安全区
                    // 顶的 68pt，Hero 位置/尺寸一丝不动（outer 仍是全屏尺寸）。
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
                .background(LiziTokens.paper)
            }
            .background(LiziTokens.paper)
        }
        .task {
            await viewModel.initialLoad()
        }
        .onChange(of: viewModel.selectedRail) { selection in
            // P2 集成缝合：rail 详情不再用 sheet，改走 AppNavigation（工人 A 已落地
            // .rail(kind:platform:)），与其它详情页同一套导航；选完即清掉触发态。
            if let selection {
                nav.show(.rail(kind: selection.kind.rawValue, platform: selection.platform))
                viewModel.selectedRail = nil
            }
        }
        .onChange(of: playback.currentTrack) { track in
            if let track = track {
                Task { @MainActor in viewModel.notePlayed(track) }
            }
        }
        .onChange(of: playback.isLiked) { _ in
            // 星标变了：正在看喜欢 rail 时刷新该 rail（本地星标兜底的平台
            // 靠这一刷把新点的星标列进来）。
            if viewModel.selectedSource == .liked {
                Task { await viewModel.loadRail(.liked) }
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("LIZI")
                    .font(.liziDisplay(size: LiziTokens.size25))
                    .foregroundColor(LiziTokens.ink)
                Text("kun")
                    .font(.liziBody(size: LiziTokens.size16, weight: .medium).italic())
                    .foregroundColor(LiziTokens.ink2)
            }
            Spacer()
            Button(action: { nav.show(.search) }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 40, height: 40)
                    .background(LiziTokens.paper2)
                    .clipShape(Circle())
            }
            .accessibilityLabel("搜索")
            Button(action: { nav.show(.settings) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 40, height: 40)
                    .background(LiziTokens.paper2)
                    .clipShape(Circle())
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal, 16)
    }
}

/// 一条 rail 的行（P2）：标题 + 横向卡片 + 点开展开。
///
/// - 标题行：rail 名 + 右侧「展开」按钮（有内容时才显示）。
/// - 卡片：曲目卡（封面 + 歌名 + 歌手）/ 歌单卡 / 电台频道卡
///   （封面 + 名字 + 副标题）；分组说明卡（groupHeader）只在详情页出现，
///   行里跳过。点任意卡片都进详情页（RailDetailView），不在行里直接播。
/// - 空态：请求失败显示失败原因 + 重试；内容为空显示诚实原因
///   （未登录 / 接口缺失 / 本地星标为空三种原因分开写，不都写「暂无内容」）。
/// - 封面无图用白色底 + 音符占位（CoverImageView）；禁缩放（不加任何
///   magnification 手势）。
private struct RailRowView: View {
    let kind: RailKind
    /// 当前平台：喜欢 rail 的标题按平台取真名（`displayTitle`），
    /// 不能只凭 kind 定。
    let platform: String
    let result: RailResult?
    let isLoading: Bool
    let onExpand: () -> Void
    let onRetry: () -> Void

    /// 行标题（喜欢 rail 按平台取真名，其余 rail 固定名）。
    private var displayTitle: String { kind.displayTitle(platform: platform) }

    /// 行里只放可点的卡片，分组说明卡跳过（只在详情页出现）。
    private var cards: [RailEntry] {
        (result?.entries ?? []).filter {
            if case .groupHeader = $0 { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(displayTitle)
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(LiziTokens.ink)
                Spacer()
                if !cards.isEmpty {
                    Button(action: onExpand) {
                        HStack(spacing: 4) {
                            Text("展开")
                                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(LiziTokens.ink2)
                    }
                    .accessibilityLabel("展开\(displayTitle)")
                }
            }
            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在拉取\(displayTitle)…")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.ink3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else if let error = result?.error {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.accent)
                            .multilineTextAlignment(.center)
                        Button("重试", action: onRetry)
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            .foregroundColor(LiziTokens.ink2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .padding(.horizontal, 24)
                } else if cards.isEmpty {
                    Text(result?.emptyReason ?? "暂无内容。")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .padding(.horizontal, 24)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(cards) { entry in
                                Button(action: onExpand) {
                                    railCard(entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(railCardLabel(entry))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func railCard(_ entry: RailEntry) -> some View {
        switch entry {
        case .track(let track):
            VStack(alignment: .leading, spacing: 7) {
                CoverImageView(url: track.coverURL, placeholderIconSize: 28)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                Text(track.title)
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        case .playlist(let playlist):
            VStack(alignment: .leading, spacing: 7) {
                CoverImageView(url: playlist.coverURL, placeholderIconSize: 28)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                Text(playlist.title)
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(playlist.trackCount > 0 ? "\(playlist.trackCount) 首" : (playlist.creator.isEmpty ? "歌单" : playlist.creator))
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        case .station(let station):
            VStack(alignment: .leading, spacing: 7) {
                CoverImageView(url: station.coverURL, placeholderIconSize: 28)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                Text(station.name)
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(station.creator.isEmpty ? "电台" : station.creator)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        case .groupHeader:
            EmptyView()
        }
    }

    private func railCardLabel(_ entry: RailEntry) -> String {
        switch entry {
        case .track(let track): return "打开\(displayTitle)：\(track.title)"
        case .playlist(let playlist): return "打开\(displayTitle)：\(playlist.title)"
        case .station(let station): return "打开\(displayTitle)：\(station.name)"
        case .groupHeader: return displayTitle
        }
    }
}

/// 「我的专辑」入口已由工人 C 的 MyAlbumsEntryView 接管（见 HomeView 收藏歌单 rail 区）。
