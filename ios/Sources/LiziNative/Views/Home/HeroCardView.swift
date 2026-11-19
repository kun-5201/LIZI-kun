import SwiftUI

/// 首页 Hero 大卡：照抄壳版 `.hall-hero`。
///
/// - 3:1 横条；min-height clamp(190px, 26vh, 260px)，
///   max-height clamp(360px, 56vh, 620px)；圆角 3px。
/// - 显示上次播放的歌（PlaybackStore.currentTrack，空时取持久化的上次播放；
///   两者都没有时标题是「从下面挑一个平台开始」）。
/// - 封面宽图铺满 + 底部渐变；左上角「上次听到 · 时间」徽章；
///   左下角歌名 / 副标题；右下角「打开歌单」+ 播放键
///   （播放中三角变均衡条动画，照抄壳版 .hall-hero__play-bars）。
/// - 右上角锁按钮：有海报时才出现；锁定 = 闭锁图标，解锁 = 开锁图标；
///   状态 UserDefaults 持久化（`lizi.native.hall.heroLocked`），默认解锁。
/// - 点按整卡进播放页；左右滑切歌（左滑 = 上一首、右滑 = 下一首，
///   锁定时失效）。上下拖动改卡片尺寸是 P5 的活，P1 不做；
///   竖向滚动用 simultaneousGesture 保证不被横滑手势吃掉。
/// - 壳版悬停才展开的歌词 / 方形封面是桌面 hover 交互，原生触屏没有 hover，
///   P1 不做；歌词在播放页看。
struct HeroCardView: View {
    let width: CGFloat
    let viewHeight: CGFloat

    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation
    @ObservedObject var viewModel: HomeViewModel

    /// 切歌锁：UserDefaults 持久化，默认解锁（照抄壳版第 12 轮第 17 件）。
    @AppStorage("lizi.native.hall.heroLocked") private var locked = false

    private var track: Track? {
        playback.currentTrack ?? viewModel.lastTrack
    }

    /// CSS clamp 的 SwiftUI 版：height = clamp(width/3, minH, maxH)，
    /// minH = clamp(26vh, 190, 260)，maxH = clamp(56vh, 360, 620)。
    private var cardHeight: CGFloat {
        let minH = min(max(viewHeight * 0.26, 190), 260)
        let maxH = min(max(viewHeight * 0.56, 360), 620)
        return min(max(width / 3, minH), maxH)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 底图：封面宽图；无封面时用纸面渐变兜底（不用金色占位）。
            if let url = track?.coverURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    LiziTokens.paper2
                }
                .frame(width: width, height: cardHeight)
                .clipped()
            } else {
                LinearGradient(
                    colors: [LiziTokens.paper2, LiziTokens.paper],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }

            // 底部署名渐变（壳版 .hall-hero__scrim）。
            LinearGradient(
                colors: [.clear, .black.opacity(track == nil ? 0 : 0.68)],
                startPoint: .init(x: 0.5, y: 0.34), endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                // 顶行：徽章 + 锁按钮。
                HStack(alignment: .top) {
                    if let at = viewModel.lastPlayedAt, track != nil {
                        Text("上次听到 · \(agoString(from: at))")
                            .font(.liziMono(size: LiziTokens.size12, weight: .medium))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.78))
                            .textCase(.uppercase)
                    }
                    Spacer()
                    // 无海报时隐藏（壳版 paintHeroLock：has=false 时 hidden）。
                    if track != nil {
                        Button(action: { locked.toggle() }) {
                            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .background(locked ? Color.white.opacity(0.94) : Color.black.opacity(0.40))
                                .foregroundColor(locked ? LiziTokens.ink : Color.white.opacity(0.84))
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                        }
                        .accessibilityLabel(locked ? "已锁定：滑动切歌已停用" : "已解开：可左右滑动切歌")
                    }
                }

                Spacer()

                // 底行：歌名 / 副标题 + 打开歌单 + 播放键。
                HStack(alignment: .bottom, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(track?.title ?? "从下面挑一个平台开始")
                            .font(.liziDisplay(size: LiziTokens.size25))
                            .foregroundColor(track == nil ? LiziTokens.ink2 : .white)
                            .lineLimit(1)
                        if let track = track {
                            Text(subtitle(for: track))
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(.white.opacity(0.76))
                                .lineLimit(1)
                        } else {
                            Text("点一个平台图标，切到它的公开内容")
                                .font(.liziBody(size: LiziTokens.size13))
                                .foregroundColor(LiziTokens.ink3)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if track != nil {
                        HStack(spacing: 12) {
                            // 「打开歌单」：P1 还没有歌单详情页（P2），先跳播放页；
                            // P2 接歌单详情时把这里改成 playlistDetail。
                            Button(action: { nav.show(.player) }) {
                                Text("打开歌单")
                                    .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .padding(.horizontal, 16)
                                    .frame(height: 40)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 999)
                                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                                    )
                            }
                            Button(action: togglePlay) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white.opacity(0.95))
                                        .frame(width: 52, height: 52)
                                    if playback.isPlaying {
                                        EQBarsView()
                                    } else {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(LiziTokens.ink)
                                    }
                                }
                            }
                            .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(width: width, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 18)
        .contentShape(Rectangle())
        .onTapGesture { nav.show(.player) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .local)
                .onEnded { value in
                    guard !locked else { return }
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 60, abs(dx) > abs(dy) else { return }
                    // 左滑 = 上一首，右滑 = 下一首（用户 2026-11-19 定向）。
                    // 注意 PlaybackStore.previous() 在进度 > 3 秒时先回到开头，
                    // 那是播放器通用行为，不是切歌失效。
                    if dx < 0 { playback.previous() } else { playback.next() }
                }
        )
    }

    private func togglePlay() {
        if playback.currentTrack != nil {
            playback.togglePlay()
        } else if let track = track {
            playback.play(track)
        }
    }

    private func subtitle(for track: Track) -> String {
        var parts: [String] = []
        if !track.artist.isEmpty { parts.append(track.artist) }
        if !track.album.isEmpty { parts.append(track.album) }
        if let q = playback.actualQuality, playback.currentTrack?.id == track.id {
            parts.append(q.displayName)
        }
        return parts.joined(separator: " · ")
    }

    /// 照抄壳版 app.js ago()：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期。
    private func agoString(from date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        let days = hours / 24
        if days < 30 { return "\(days) 天前" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

/// 播放中的三条均衡条（壳版 .hall-hero__play-bars：三条 scaleY 呼吸，
/// 周期 0.82 / 0.62 / 0.94 秒，错开相位）。
private struct EQBarsView: View {
    @State private var animating = false

    private let durations: [Double] = [0.82, 0.62, 0.94]
    private let delays: [Double] = [0, 0.2, 0.45]
    private let peaks: [CGFloat] = [1.0, 0.6, 0.85]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(LiziTokens.ink)
                    .frame(width: 3, height: 14)
                    .scaleEffect(y: animating ? peaks[i] : 0.35, anchor: .center)
                    .animation(
                        Animation.easeInOut(duration: durations[i])
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: animating
                    )
            }
        }
        .frame(height: 16)
        .onAppear { animating = true }
    }
}
