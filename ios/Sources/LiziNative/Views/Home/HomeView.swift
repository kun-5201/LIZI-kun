import SwiftUI

/// 首页（大厅）：顶栏 + Hero 大卡 + 平台条 + 来源 chips + 每日推荐跑马带。
///
/// 布局自上而下（照抄壳版大厅结构，P1 只做这几块）：
/// 1. 顶栏：品牌「LIZI」+ kun 斜体字（文字排版，不要图片）；
///    右侧搜索（进搜索页）与设置齿轮。
/// 2. Hero 大卡（HeroCardView）。
/// 3. 平台条（PlatformStripView）：7 家平台横排，点按切台。
/// 4. 来源 chips（SourceChipsView）：每日推荐 / 精选 / 我的喜欢 /
///    我收藏的歌单 / 电台——P1 用横向 chips，球面滚轮是 P3 打磨项。
/// 5. 内容区：每日推荐 = 跑马带；其余来源 = 诚实空态（SourceEmptyView）。
/// 6. 本地音乐区占位（P4 的活，只留行，不放假列表）。
///
/// 设置齿轮的决定（P1）：保留齿轮按钮，点按后在本页顶部出现一行空态提示
/// 「设置页 P3 上线」，再点提示可关掉——不是死按钮，也不提前做设置页。
/// P0 脚手架的构建信息行（LiziNativeBuildInfo）已从首页撤下，
/// 构建信息改由 P3 设置页「关于 → 构建」展示。
struct HomeView: View {
    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation
    @StateObject private var viewModel = HomeViewModel()
    @State private var showSettingsNote = false

    var body: some View {
        GeometryReader { outer in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    topBar
                    if showSettingsNote {
                        settingsNoteBanner
                    }
                    HeroCardView(
                        width: outer.size.width - 32,
                        viewHeight: outer.size.height,
                        viewModel: viewModel
                    )
                    .padding(.horizontal, 16)

                    PlatformStripView(viewModel: viewModel)

                    SourceChipsView(viewModel: viewModel)

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
                    } else {
                        SourceEmptyView(
                            source: viewModel.selectedSource,
                            platformName: LiziPlatforms.all.first(where: { $0.id == viewModel.selectedPlatform })?.name ?? viewModel.selectedPlatform,
                            likedCount: viewModel.likedCount
                        )
                    }

                    LocalMusicPlaceholderView()
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(LiziTokens.paper)
        }
        .task {
            await MainActor.run {
                await viewModel.initialLoad()
            }
        }
        .onChange(of: playback.currentTrack) { track in
            if let track = track {
                Task { @MainActor in viewModel.notePlayed(track) }
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 0) {
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
            Button(action: { showSettingsNote.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 40, height: 40)
                    .background(LiziTokens.paper2)
                    .clipShape(Circle())
            }
            .accessibilityLabel("设置（P3 上线）")
        }
        .padding(.horizontal, 16)
    }

    private var settingsNoteBanner: some View {
        Button(action: { showSettingsNote = false }) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                    .foregroundColor(LiziTokens.ink3)
                Text("设置页 P3 上线，这里先是空态。点一下关掉。")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
                Spacer()
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LiziTokens.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(LiziTokens.paper2)
            .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}
