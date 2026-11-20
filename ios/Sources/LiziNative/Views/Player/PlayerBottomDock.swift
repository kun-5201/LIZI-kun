import SwiftUI

/// 播放页底部三排（r27，v4 合成图 ~/workspace/lizi-player-v4-composite.png，
/// 1206×2622 @3x，屏 402pt；只用于竖屏默认版式，横屏与 02/04/06 变体不动）。
///
/// 从下往上（v4 图实测，px ÷ 3 = pt）：
/// - 最下面一排（中心 y≈2430px = 810pt）：音乐模式 / 上一首 / 暂停播放
///   （大白圆居中）/ 下一首 / 播放列表。5 格按宽比
///   0.17 / 0.20 / 0.26 / 0.20 / 0.17 排（实测圆心 x 43/110/201/292/359pt，
///   与该比例算出的 48/116/201/286/355 差 ≤6pt）；大白圆 Ø184px = 61.3pt
///   → 标准档 61pt（compact 48 / large 68，按 playSize 档比缩放）。
///   上一首/下一首是「竖线 + 单三角」（backward.end.fill / forward.end.fill），
///   不是控制行用的双三角 backward.fill。
/// - 第 2 排（进度条中心 y≈2270px = 756.7pt）：复用 `PlayerProgressBar`
///   （r20 可拖进度条，拖动/点按 seek 同款），下面加一行两端时间
///   （当前 / 总时长，11pt）；进度条左右各留约 27pt 是图里的画法，
///   这里与其它排对齐用内容宽（16pt 边距），只窄 10pt/边，见交回。
/// - 第 3 排（中心 y≈2090px = 696.7pt）：下载 / 喜欢 / 评论区 / 选择音质，
///   4 键均分一行（实测圆心 x 50/151/251/352pt，正好是 4 等分中心）。
///   选择音质是显示当前音质的小芯片（图里「无损」，116×52px = 38.7×17.3pt，
///   白框圆角 + 11pt 字）；没在播时显示「标准」（默认）。
///
/// 接线（功能全部真实现，不是空壳）：
/// - 音乐模式：一个键在 循环 → 单曲 → 随机 之间切，图标跟着变
///   （repeat / repeat.1 / shuffle），状态复用 PlaybackStore 已有的
///   repeatMode + isShuffled（都已持久化，不另造状态；循环逻辑见
///   cycleDockMode——随机态下 repeatMode 原值不动，离开随机时还原）。
///   注意：顺序（repeatMode=.off 且随机 off）不在三态里，图标是白色
///   repeat，点按进循环；队列面板头部仍可单独切顺序/随机（原有入口不动）。
/// - 上一首 / 下一首 / 暂停：store.previous() / next() / togglePlay()。
/// - 播放列表：调用方传的 onOpenQueue（PlayerView 的 showQueue，
///   队列面板仍只盖住歌词区，见 lyricsZone）。
/// - 喜欢：store.toggleLike()（已喜欢 heart.fill 红色实心）。
/// - 下载：DownloadStore（取链复用播放编排，落盘进 LocalMusic 清单）。
/// - 评论区：CommentsPanelView（只读；网易云真实评论，其它平台老实写清没有）。
/// - 选择音质：点开 9 档选择器，选了调 setPreferredQuality 并重播当前曲
///   （从原进度继续，见 switchQuality；显示的永远是实际返回档位）。
/// - 音量不在三排里：r28 已删第二行，App 内无音量按钮，音量走机身键/控制中心。
/// - 无曲目时整排 disabled（与 PlayerControlRow 同款）。
/// - 禁缩放：本文件没有任何 MagnificationGesture / 捏合手势。
struct PlayerBottomDock: View {
    @EnvironmentObject private var store: PlaybackStore
    @ObservedObject private var downloads = DownloadStore.shared

    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 内容宽（调用方 PlayerView 的 contentWidth = 屏宽 − 2×16）。
    var width: CGFloat = 370
    /// 播放列表键的回调（调用方一般传 `{ showQueue.toggle() }`）。
    var onOpenQueue: (() -> Void)? = nil

    @State private var showComments = false
    @State private var showQualityPicker = false

    // MARK: - 分档尺寸（v4 图实测，见文件头）

    /// 大播放键直径：v4 图 Ø184px = 61.3pt（标准档取 61）；
    /// compact / large 按 playSize 档比（60/68/76）缩放。
    /// r27 压缩：compact 48 → 42（只压 compact 档，见 PlayerView 文件底
    /// r27 段落；播放图标 = 直径 × 0.44 ≈ 18.5pt，点按区仍是整格宽）。
    private var playDiameter: CGFloat {
        switch tier {
        case .compact: return 42
        case .standard: return 61
        case .large: return 68
        }
    }

    /// 第 3 排行高（图标 22pt 字号，上下留空）。
    /// r27 压缩：compact 28 → 26（音质芯片约 23pt 高，仍放得下）。
    private var actionRowHeight: CGFloat {
        switch tier {
        case .compact: return 26
        case .standard: return 32
        case .large: return 32
        }
    }

    /// 第 3 排图标字号（v4 图标约 16–17pt 字形高；SF 字形高约 0.8em）。
    /// r27 压缩：compact 20 → 18（配 26pt 行高，字形约 14.4pt）。
    private var actionIconFont: CGFloat {
        switch tier {
        case .compact: return 18
        case .standard: return 22
        case .large: return 24
        }
    }

    /// 排间距（r27 压缩：compact 4 → 2，两排共省 4pt，见 PlayerView
    /// 文件底 r27 总账；其余档 8 不动）。
    private var dockGap: CGFloat { tier == .compact ? 2 : 8 }

    /// 第 2 排内间距（进度条 → 时间行）：compact 2（r27 压缩，省 2pt）；
    /// 其余档 4。时间字号 compact 仍是 10pt，不动。
    private var progressSpacing: CGFloat { tier == .compact ? 2 : 4 }

    /// 传输行小图标字号（与控制行同款分档）。
    private var transportIconFont: CGFloat { PlayerTokens.controlIconSize(tier) }

    /// 第 2 排时间字号。
    private var timeFont: CGFloat {
        switch tier {
        case .compact: return 10
        case .standard: return 11
        case .large: return 12
        }
    }

    var body: some View {
        VStack(spacing: dockGap) {
            actionRow
            progressRow
            transportRow
        }
        .disabled(store.currentTrack == nil)
        .onAppear { downloads.refreshDownloadedCache() }
        .sheet(isPresented: $showComments) {
            Group {
                if let track = store.currentTrack {
                    CommentsPanelView(track: track)
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
        }
        .sheet(isPresented: $showQualityPicker) {
            qualityPickerSheet
        }
    }

    // MARK: - 第 3 排：下载 / 喜欢 / 评论区 / 选择音质（4 等分）

    private var actionRow: some View {
        HStack(spacing: 0) {
            downloadCell
                .frame(width: width / 4)
            likeCell
                .frame(width: width / 4)
            commentsCell
                .frame(width: width / 4)
            qualityCell
                .frame(width: width / 4)
        }
        .frame(height: actionRowHeight)
    }

    /// 下载键（DownloadStore.shared；图标按状态换：空闲箭头 / 下载中环形
    /// 进度 / 下完勾 / 失败红三角点按重试；试听片段不下载，
    /// 见 DownloadStore；本地歌直接显示勾）。
    private var downloadCell: some View {
        let track = store.currentTrack
        let key = track.map { DownloadStore.key(for: $0) }
        let state: DownloadStore.DownloadState = {
            guard let track, let key else { return .idle }
            return downloads.state(forKey: key, track: track)
        }()
        return Button(action: {
            guard let track else { return }
            Task { @MainActor in await downloads.start(track: track, store: store) }
        }) {
            downloadIcon(state: state)
        }
        .disabled(track == nil)
        .accessibilityLabel(downloadAccessibilityLabel(state: state))
        .accessibilityValue(downloadAccessibilityValue(state: state))
    }

    @ViewBuilder
    private func downloadIcon(state: DownloadStore.DownloadState) -> some View {
        switch state {
        case .idle:
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: actionIconFont, weight: .medium))
                .foregroundStyle(PlayerTokens.playerForeground)
        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .tint(PlayerTokens.playerForeground)
                .frame(width: actionIconFont, height: actionIconFont)
        case .downloaded:
            Image(systemName: "checkmark")
                .font(.system(size: actionIconFont, weight: .semibold))
                .foregroundStyle(PlayerTokens.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: actionIconFont, weight: .medium))
                .foregroundStyle(Color.red)
        }
    }

    private func downloadAccessibilityLabel(state: DownloadStore.DownloadState) -> String {
        switch state {
        case .idle: return "下载到本地"
        case .downloading: return "正在下载"
        case .downloaded: return "已下载到本地"
        case .failed(let message): return "下载失败：\(message)，点按重试"
        }
    }

    private func downloadAccessibilityValue(state: DownloadStore.DownloadState) -> String {
        if case .downloading(let progress) = state { return "已下载 \(Int(progress * 100))%" }
        return ""
    }

    /// 喜欢键（store.toggleLike；已喜欢 heart.fill 红色实心）。
    private var likeCell: some View {
        Button(action: { store.toggleLike() }) {
            Image(systemName: store.isLiked ? "heart.fill" : "heart")
                .font(.system(size: actionIconFont, weight: .medium))
                .foregroundStyle(store.isLiked ? Color.red : PlayerTokens.playerForeground)
        }
        .accessibilityLabel(store.isLiked ? "取消喜欢" : "喜欢")
    }

    /// 评论区键（点开 CommentsPanelView；只读）。
    private var commentsCell: some View {
        Button(action: { showComments = true }) {
            Image(systemName: "bubble.left")
                .font(.system(size: actionIconFont, weight: .medium))
                .foregroundStyle(PlayerTokens.playerForeground)
        }
        .accessibilityLabel("评论区")
    }

    /// 选择音质芯片（显示当前音质：实际返回档位，没有时默认「标准」；
    /// 点开 9 档选择器，选了真换音质，见 switchQuality）。
    private var qualityCell: some View {
        Button(action: { showQualityPicker = true }) {
            Text(store.actualQuality?.displayName ?? "标准")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PlayerTokens.playerForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                )
        }
        .accessibilityLabel("选择音质，当前\(store.actualQuality?.displayName ?? "标准")")
    }

    // MARK: - 第 2 排：进度条（复用）+ 两端时间

    private var progressRow: some View {
        VStack(spacing: progressSpacing) {
            PlayerProgressBar(tier: tier)
                .frame(width: width)
            HStack {
                Text(PlayerTokens.formatDuration(store.progress))
                    .font(.system(size: timeFont))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .monospacedDigit()
                Spacer()
                Text(PlayerTokens.formatDuration(store.duration))
                    .font(.system(size: timeFont))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .monospacedDigit()
            }
        }
    }

    // MARK: - 最下面一排：模式 / 上一首 / 播放 / 下一首 / 播放列表

    private var transportRow: some View {
        HStack(spacing: 0) {
            modeCell
                .frame(width: width * 0.17)
            Button(action: { store.previous() }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: transportIconFont))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .frame(width: width * 0.20)
            .accessibilityLabel("上一首")
            playCell
                .frame(width: width * 0.26)
            Button(action: { store.next() }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: transportIconFont))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .frame(width: width * 0.20)
            .accessibilityLabel("下一首")
            Button(action: { onOpenQueue?() }) {
                Image(systemName: "list.bullet")
                    .font(.system(size: transportIconFont, weight: .medium))
                    .foregroundStyle(PlayerTokens.playerForeground)
            }
            .frame(width: width * 0.17)
            .accessibilityLabel("打开播放队列")
        }
        .frame(height: playDiameter)
    }

    /// 大播放键（白圆 + 黑三角/暂停；加载中转圈，与 PlayerControlRow 同款）。
    private var playCell: some View {
        Button(action: { store.togglePlay() }) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: playDiameter, height: playDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
                if store.isLoading {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: playDiameter * 0.44, weight: .semibold))
                        .foregroundStyle(.black)
                        .offset(x: store.isPlaying ? 0 : 2)
                }
            }
        }
        .accessibilityLabel(store.isPlaying ? "暂停" : "播放")
    }

    // MARK: - 音乐模式：循环 → 单曲 → 随机（三态一键，复用已有状态）

    /// 三态 + 顺序（不在循环里）：随机开 → 随机；否则看 repeatMode。
    private enum DockPlayMode { case all, one, shuffle, off }

    private var dockMode: DockPlayMode {
        if store.isShuffled { return .shuffle }
        switch store.repeatMode {
        case .all: return .all
        case .one: return .one
        case .off: return .off
        }
    }

    private var modeIconName: String {
        switch dockMode {
        case .all, .off: return "repeat"
        case .one: return "repeat.1"
        case .shuffle: return "shuffle"
        }
    }

    private var modeTitle: String {
        switch dockMode {
        case .all: return "循环"
        case .one: return "单曲"
        case .shuffle: return "随机"
        case .off: return "顺序"
        }
    }

    private var modeCell: some View {
        Button(action: { cycleDockMode() }) {
            Image(systemName: modeIconName)
                .font(.system(size: transportIconFont, weight: .medium))
                .foregroundStyle(dockMode == .off ? PlayerTokens.playerForeground : PlayerTokens.accent)
        }
        .accessibilityLabel("播放模式：\(modeTitle)，点按切换")
    }

    /// 三态循环（只调已有的 cycleRepeatMode / setShuffled，不另造状态）：
    /// - 循环 → 单曲：cycleRepeatMode（all → one）。
    /// - 单曲 → 随机：setShuffled(true)；repeatMode 保持 one 不动。
    /// - 随机 → 循环：先关随机；repeatMode 是 one 时连切两次（one → off → all），
    ///   是 off 时切一次（off → all），已是 all 时不动。
    /// - 顺序（off 且随机 off，不在三态里）→ 循环：切一次（off → all）。
    private func cycleDockMode() {
        switch dockMode {
        case .all:
            store.cycleRepeatMode()
        case .one:
            store.setShuffled(true)
        case .shuffle:
            store.setShuffled(false)
            if store.repeatMode == .one {
                store.cycleRepeatMode()
                store.cycleRepeatMode()
            } else if store.repeatMode == .off {
                store.cycleRepeatMode()
            }
        case .off:
            store.cycleRepeatMode()
        }
    }

    // MARK: - 音质选择器（sheet）

    /// 9 档音质选择器（复用 SettingsView 音效页同一套档位 + 同一个写口
    /// setPreferredQuality；显示的永远是实际返回档位，见芯片）。
    private var qualityPickerSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择音质")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("切换后从当前位置继续播放（重新取链）；显示的永远是实际返回的档位。")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    Spacer()
                    Button(action: { showQualityPicker = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.16), in: Circle())
                    }
                    .accessibilityLabel("关闭音质选择")
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
                Text("当前实际：\(store.actualQuality?.displayName ?? "—")")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                List {
                    ForEach(AudioQuality.allCases, id: \.self) { quality in
                        Button(action: { switchQuality(to: quality) }) {
                            HStack {
                                Text(quality.displayName)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white)
                                Spacer()
                                if store.preferredQuality == quality {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(PlayerTokens.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// 换音质真生效：先写请求档位，再重播当前曲（队列位置不变，
    /// 取链走新档位），等起播后回到原进度；原来是暂停的播完仍暂停。
    /// 等起播最多 3 秒（startedTrackId 对上才 seek；中途切歌就放弃，
    /// 不把旧进度 seek 到新歌头上）。
    private func switchQuality(to quality: AudioQuality) {
        store.setPreferredQuality(quality)
        showQualityPicker = false
        guard let track = store.currentTrack else { return }
        guard store.isPlaying || store.progress > 1 else { return }
        let position = store.progress
        let wasPlaying = store.isPlaying
        Task { @MainActor in
            store.play(track)
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard store.currentTrack?.id == track.id,
                      store.currentTrack?.platform == track.platform else { return }
                if store.startedTrackId == track.id { break }
            }
            guard store.currentTrack?.id == track.id,
                  store.currentTrack?.platform == track.platform else { return }
            if position > 1 { store.seek(to: position) }
            if !wasPlaying { store.pause() }
        }
    }
}
