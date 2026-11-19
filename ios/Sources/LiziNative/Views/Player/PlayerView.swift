import SwiftUI

/// 播放页（原生版屏幕 3，对照壳版 `#view-now`）。
///
/// 导航（P1-B 的 `AppNavigation`，已合入 `Sources/LiziNative/AppNavigation.swift`，
/// 本文件按约定引用，不新建导航、不改 `RootView.swift`）：`AppNavigation` 是
/// `@EnvironmentObject`，`enum AppView { case home, search, player }`，
/// `show(_:)` 切页。P1 集成已把 RootView 的 `.player` 换成 `PlayerView()`；
/// `PlaybackStore` 与 `AppNavigation` 都已由 App / RootView 经 environmentObject
/// 下发，本页直接取用。
///
/// 纵向结构（按任务书条目顺序；与壳版有一处不同，见注释）：
/// 顶栏 → 3D 封面流（上半部分）→ 歌名/歌手 → 传输排 → 歌词/队列面板 → 底部 dock。
/// 壳版窄屏是「封面流 → 歌词（弹性中段）→ 歌名/传输排（底部）」；这里歌词面板
/// 放在传输排下方、dock 上方，如需与壳版一致，把 `panelArea` 与 `metaAndTransport`
/// 两段对调即可。
///
/// - 禁缩放：本页没有任何 MagnificationGesture / 捏合手势，尺寸全部固定值，
///   不随手势变化（MEMORY：任何操作禁缩放）。
/// - 底部留 Home Indicator 安全区：dock 用 `safeAreaInset(edge: .bottom)` 挂，
///   坐在安全区之上，不被 Home Indicator 压住。
/// - 无曲目时是空态（标题「未在播放」），不编假数据。
struct PlayerView: View {
    @EnvironmentObject private var store: PlaybackStore
    @EnvironmentObject private var navigation: AppNavigation

    @State private var panelExpanded = false
    @State private var panelTab: PlayerPanelTab = .lyrics

    /// 有逐字歌词时顶栏中部显示「逐字」徽章。
    private var hasWordLyrics: Bool {
        store.lyrics.contains { !$0.words.isEmpty }
    }

    var body: some View {
        GeometryReader { geo in
            let isShortScreen = geo.size.height < 700
            ZStack {
                background
                VStack(spacing: 0) {
                    topBar
                    CoverFlowView(isCompact: panelExpanded || isShortScreen)
                        .padding(.top, 6)
                    metaAndTransport
                    panelArea
                }
                .padding(.horizontal, PlayerTokens.sp4)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerDockView()
        }
        // 禁缩放：SwiftUI 默认没有捏合缩放；这里明确不加任何缩放手势。
        .navigationBarHidden(true)
    }

    // MARK: - 背景：模糊封面大图（blur 64px）+ 暗角；无封面用默认深色渐变

    private var background: some View {
        ZStack {
            if let url = store.currentTrack?.coverURL {
                CoverImageView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 64)
                    .scaleEffect(1.25)
            } else {
                LinearGradient(
                    colors: [PlayerTokens.ink, Color.black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // 压暗 + 暗角，保证白字可读（壳版 .now__bg 那层暗场）。
            Color.black.opacity(0.45)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.clear,
                    Color.clear,
                    Color.black.opacity(0.55),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.42), value: store.currentTrack?.id)
    }

    // MARK: - 顶栏：左返回；中「逐字」徽章；右搜索、控制

    private var topBar: some View {
        HStack {
            Button(action: { navigation.show(.home) }) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("返回")
                        .font(.system(size: PlayerTokens.textMd))
                }
                .foregroundStyle(PlayerTokens.playerForeground)
            }
            .accessibilityLabel("返回首页")

            Spacer()

            if hasWordLyrics {
                Text("逐字")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(PlayerTokens.accent)
                    .clipShape(Capsule())
                    .accessibilityLabel("逐字歌词")
            }

            Spacer()

            HStack(spacing: 20) {
                Button(action: { navigation.show(.search) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(PlayerTokens.playerForeground)
                }
                .accessibilityLabel("搜索")
                // 搜索页聚焦由搜索页负责：进搜索页时自动聚焦输入框（P1 搜索页 / 集成时接）。

                Button(action: toggleQueuePanel) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(PlayerTokens.playerForeground)
                }
                .accessibilityLabel("控制：打开播放队列")
                // P1 先打开队列面板。抽屉里的 EQ / DIY / 形态是 P3 的活，
                // 到时这个按钮再改成开抽屉。
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 「控制」按钮：P1 打开队列面板（再点一次收起）。
    private func toggleQueuePanel() {
        if panelTab == .queue, panelExpanded {
            panelExpanded = false
        } else {
            panelTab = .queue
            panelExpanded = true
        }
    }

    // MARK: - 歌名 / 歌手 + 传输排

    private var metaAndTransport: some View {
        VStack(spacing: 0) {
            titleBlock
                .padding(.top, 12)
            transportRow
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 2) {
            Text(store.currentTrack?.title ?? "未在播放")
                // 标题 39px；Fraunces 未打包进原生 target，用 DesignTokens 的
                // liziDisplay（系统 serif 近似，见 Views/Home/DesignTokens.swift）。
                .font(.liziDisplay(size: PlayerTokens.text3xl))
                .foregroundStyle(PlayerTokens.playerForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .center)
            Text(subtitleText)
                .font(.system(size: PlayerTokens.textSm))
                .foregroundStyle(PlayerTokens.playerSub)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            statusCapsules
        }
    }

    private var subtitleText: String {
        guard let track = store.currentTrack else { return "从首页或搜索页选一首歌开始" }
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if !track.album.isEmpty { parts.append(track.album) }
        return parts.isEmpty ? track.platform : parts.joined(separator: " · ")
    }

    /// 状态角标：只在有内容时出现 —— 实际音质（显示 = 实际返回档位，绝不显示
    /// 请求档位）、试听、演示音。取链失败的原因由下面的 error 行明示，不静默。
    @ViewBuilder
    private var statusCapsules: some View {
        if let message = store.errorMessage {
            Text(playFailureText(for: message))
                .font(.system(size: PlayerTokens.textXs))
                .foregroundStyle(Color.red.opacity(0.85))
                .padding(.top, 4)
        } else if store.currentTrack != nil {
            HStack(spacing: 6) {
                if let quality = store.actualQuality {
                    statusCapsule(quality.displayName)
                }
                if store.currentTrack?.isTrial == true {
                    statusCapsule("试听")
                }
                if store.isDemo {
                    statusCapsule("演示音")
                }
            }
            .padding(.top, 4)
        }
    }

    private func statusCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(PlayerTokens.playerForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.16))
            .clipShape(Capsule())
    }

    /// 播放失败原因明示（PlaybackStore.errorMessage 的 reason 码，不编新文案，
    /// 只翻译成用户能看懂的话）。
    private func playFailureText(for reason: String) -> String {
        switch reason {
        case "vip": return "会员歌曲，无法播放整首"
        case "unavailable": return "这首歌暂时无法播放"
        case "login": return "需要登录后才能播放"
        case "region": return "该歌曲在你所在的地区不可用"
        case "drm": return "该歌曲受版权保护，无法播放"
        case "network": return "网络有问题，稍后再试"
        default: return "这首歌暂时无法播放"
        }
    }

    // MARK: - 传输排：左模式 + 上一首；中大播放/暂停；右下一首

    private var transportRow: some View {
        HStack(spacing: 16) {
            // 左：模式按钮（点按循环顺序/全部循环/单曲循环；长按切换随机）+ 上一首。
            HStack(spacing: 16) {
                modeButton
                Button(action: { store.previous() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(PlayerTokens.playerForeground)
                }
                .accessibilityLabel("上一首")
            }
            Spacer()
            playButton
            Spacer()
            Button(action: { store.next() }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .accessibilityLabel("下一首")
        }
        .frame(height: PlayerTokens.transportPlaySize)
        .disabled(store.currentTrack == nil)
    }

    /// 模式按钮：图标接 `repeatMode` + `isShuffled`。
    /// - 点按：`cycleRepeatMode()`（顺序 → 全部循环 → 单曲循环）。
    /// - 长按：`setShuffled(!isShuffled)`（随机开关）。
    /// - 随机开时显示 shuffle 图标；否则按循环模式显示 repeat / repeat.1。
    /// 故意不用 Button：Button + onLongPressGesture 在部分 iOS 版本上长按后
    /// 还会再触发一次点按（循环模式被多切一档），纯手势写法不会。
    private var modeButton: some View {
        Image(systemName: modeIconName)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(modeIconColor)
            .frame(width: PlayerTokens.transportButtonSize,
                   height: PlayerTokens.transportButtonSize)
            .contentShape(Rectangle())
            .onTapGesture { store.cycleRepeatMode() }
            .onLongPressGesture(minimumDuration: 0.5) {
                store.setShuffled(!store.isShuffled)
            }
            .accessibilityLabel(modeAccessibilityLabel)
    }

    private var modeIconName: String {
        if store.isShuffled { return "shuffle" }
        switch store.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var modeIconColor: Color {
        if store.isShuffled { return PlayerTokens.accent }
        switch store.repeatMode {
        case .off: return PlayerTokens.playerDim
        case .all, .one: return PlayerTokens.accent
        }
    }

    private var modeAccessibilityLabel: String {
        let repeatText: String
        switch store.repeatMode {
        case .off: repeatText = "顺序播放"
        case .all: repeatText = "全部循环"
        case .one: repeatText = "单曲循环"
        }
        return store.isShuffled ? "随机播放已开，长按关闭" : "\(repeatText)，点按切换，长按开随机"
    }

    private var playButton: some View {
        Button(action: { store.togglePlay() }) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: PlayerTokens.transportPlaySize,
                           height: PlayerTokens.transportPlaySize)
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
                if store.isLoading {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.black)
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
        }
        .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
    }

    // MARK: - 歌词 / 队列面板（共用同一面板区域切换）

    private var panelArea: some View {
        VStack(spacing: 0) {
            panelHandle
            panelTabBar
            if panelExpanded {
                panelExpandedContent
            } else {
                panelPreviewContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 拉起手柄：上拖展开、下拖收起、点按切换。
    private var panelHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { panelExpanded.toggle() }
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .local)
                    .onEnded { value in
                        let dy = value.translation.height
                        if dy < -30 {
                            panelExpanded = true
                        } else if dy > 30 {
                            panelExpanded = false
                        }
                    }
            )
            .accessibilityLabel(panelExpanded ? "收起歌词面板" : "展开歌词面板")
    }

    private var panelTabBar: some View {
        HStack(spacing: 24) {
            panelTabButton(title: "歌词", tab: .lyrics)
            panelTabButton(title: "队列", tab: .queue, count: store.queue.count)
        }
        .padding(.bottom, 6)
    }

    private func panelTabButton(title: String, tab: PlayerPanelTab, count: Int? = nil) -> some View {
        Button(action: {
            panelTab = tab
            // 切到队列时默认展开，方便点行切歌；切回歌词保持当前展开态。
            if tab == .queue { panelExpanded = true }
        }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: PlayerTokens.textMd,
                                  weight: panelTab == tab ? .semibold : .regular))
                    .foregroundStyle(panelTab == tab
                        ? PlayerTokens.playerForeground
                        : PlayerTokens.playerDim)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(panelTab == tab ? .white : PlayerTokens.playerDim)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(panelTab == tab
                            ? PlayerTokens.accent
                            : Color.white.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                if panelTab == tab {
                    Rectangle()
                        .fill(PlayerTokens.accent)
                        .frame(height: 2)
                }
            }
        }
        .accessibilityLabel(count.map { "\(title)，共 \($0) 首" } ?? title)
    }

    @ViewBuilder
    private var panelExpandedContent: some View {
        switch panelTab {
        case .lyrics:
            FullLyricsView()
        case .queue:
            QueuePanelView()
        }
    }

    @ViewBuilder
    private var panelPreviewContent: some View {
        switch panelTab {
        case .lyrics:
            LyricsPreviewView()
                .padding(.top, 2)
        case .queue:
            QueuePreviewView()
        }
    }
}

/// 面板 Tab：歌词 / 队列（与歌词共用同一面板区域切换）。
enum PlayerPanelTab {
    case lyrics
    case queue
}
