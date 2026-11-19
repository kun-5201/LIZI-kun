import SwiftUI

/// 首页 Hero 大卡：r22j 模板 v2（~/workspace/lizi-home-template-portrait.png /
/// lizi-home-template-landscape.png）+ 壳版 `.hall-hero` 兜底。
///
/// - 模板 v2：竖屏是首屏上半块（高 = (屏高−110)/2，402×874 档 382pt），
///   横屏是满宽横幅（高 = (屏高−110)×9/16，932×430 档 180pt）；高度由
///   HomeView 按模板算好传进来（`height`），不再用壳版 clamp 公式
///   （公式保留作 `height == nil` 时的回落）。
///   圆角 17（模板量：顶行/左列都从 16 往里收 17pt；壳版是 3px，
///   模板为准）。标题 42pt（竖屏模板量约 42pt）/ 46pt（横屏模板量约
///   46pt），由 HomeView 按朝向传 `titleSize`；内边距左/右 24、上/下 20
///   （壳版 badge left 24 top 20、meta left/right 24 bottom 20）；阴影
///   0 30/35 0.5（壳版 0 30px 70px -34px / .5，SwiftUI 无 spread，
///   radius≈blur/2 近似）。
/// - 显示上次播放的歌（PlaybackStore.currentTrack，空时取持久化的上次播放；
///   两者都没有时标题是「从下面挑一个平台开始」）。
/// - 封面宽图铺满 + 底部渐变；左上角「上次听到 · 时间」徽章；
///   左下角歌名 / 副标题；右下角播放键（播放中三角变均衡条动画，
///   照抄壳版 .hall-hero__play-bars）。模板里没有「打开歌单」pill，
///   已拿掉——整卡点按就是进播放页，pill 是重复入口，功能没丢。
/// - 右上角锁按钮：有海报时才出现；锁定 = 闭锁图标，解锁 = 开锁图标；
///   状态 UserDefaults 持久化（`lizi.native.hall.heroLocked`），默认解锁。
/// - 点按整卡进播放页；双击整卡也进播放页（r20：单 / 双击都落传统
///   PlayerView，见 `openClassicPlayer()`）。左右滑切歌（左滑 = 上一首、
///   右滑 = 下一首，锁定时失效）。上下拖动改卡片尺寸是 P5 的活，P1 不做；
///   竖向滚动用 simultaneousGesture 保证不被横滑手势吃掉。
/// - 壳版悬停才展开的歌词 / 方形封面是桌面 hover 交互，原生触屏没有 hover，
///   P1 不做；歌词在播放页看。
/// - 封面只用真数据：`track?.coverURL`（正在播那首歌的封面），不用模板图。
struct HeroCardView: View {
    let width: CGFloat
    let viewHeight: CGFloat
    /// 模板 v2 定高（竖屏 382 / 横屏 180，932×430 档）；nil 时回落壳版 clamp 公式。
    var height: CGFloat? = nil
    /// 模板 v2 标题字号：竖屏 42 / 横屏 46（模板实测）。
    var titleSize: CGFloat = 42

    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation
    @ObservedObject var viewModel: HomeViewModel

    /// 切歌锁：UserDefaults 持久化，默认解锁（照抄壳版第 12 轮第 17 件）。
    @AppStorage("lizi.native.hall.heroLocked") private var locked = false

    private var track: Track? {
        playback.currentTrack ?? viewModel.lastTrack
    }

    /// 模板 v2 定高优先：`height` 有值时直接用（竖屏 (屏高−110)/2、
    /// 横屏 (屏高−110)×9/16）；nil 时回落壳版 clamp 公式
    /// height = clamp(width/3, minH, maxH)，minH = clamp(26vh, 190, 260)，
    /// maxH = clamp(56vh, 360, 620)。
    private var cardHeight: CGFloat {
        if let height { return height }
        let minH = min(max(viewHeight * 0.26, 190), 260)
        let maxH = min(max(viewHeight * 0.56, 360), 620)
        return min(max(width / 3, minH), maxH)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 底图：封面宽图；无封面时用纸面渐变兜底（不用金色占位）。
            if let url = track?.coverURL {
                ProxyImageView(url: url) { LiziTokens.paper2 }
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
                            .font(.liziDisplay(size: titleSize))
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
                        // 模板 v2：右下角只有播放键，没有「打开歌单」pill——
                        // 整卡点按就是进播放页，pill 是重复入口（见文件头）。
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
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(width: width, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 17)) // 模板 v2 实测圆角约 17pt（壳版 3px，模板为准）
        .shadow(color: .black.opacity(0.5), radius: 35, x: 0, y: 30)
        .contentShape(Rectangle())
        // r20 双击进播放页：双击优先、单击兜底的排他组合，一只手势包办单 / 双击。
        // - `TapGesture(count: 2).exclusively(before: TapGesture(count: 1))`：
        //   系统先等双击窗口（约 0.3 秒）：两下都落在卡片上 → 只走双击分支，
        //   单击分支绝不触发；只有一下、双击失败 → 才走单击分支。
        //   所以双击一次只进一次播放页（且单击动作要等双击窗口过后才执行，
        //   轻微延迟是这个写法的固有代价，任务书已接受）。
        // - 不能写成两个独立的 `.onTapGesture`（一个 count: 1、一个 count: 2）：
        //   两个手势互不协调，双击会先触发两次单击再触发双击。
        // - 滑动不会误触双击：滑动是一次连续触摸、只有一次抬手，成不了两次
        //   点按；且手指移动超出点按容差后两个 TapGesture 都会失败，
        //   下面 simultaneousGesture 里的 DragGesture 照常接管切歌。
        // - 卡片里的三个 Button（锁 / 打开歌单 / 播放键）是子视图手势，
        //   优先级高于父视图的 `.gesture`，点它们时父手势不触发，和原来
        //   `.onTapGesture` 时的行为一致；双击锁按钮只会开关锁两次，不进播放页。
        // - 禁缩放：这里没有任何捏合手势。
        .gesture(
            TapGesture(count: 2)
                .onEnded { openClassicPlayer() }
                .exclusively(before: TapGesture(count: 1)
                    .onEnded { openClassicPlayer() })
        )
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

    /// 进传统播放器（单击 / 双击大卡片共用；「打开歌单」按钮走同一路由）。
    ///
    /// 强制传统的办法就是只走 `.player` 路由、不碰持久化键：
    /// RootView 的 `.player` 分支永远渲染传统 PlayerView，从不读
    /// `lizi.native.playerMode`，所以不管上次停留在哪个舞台形态，进来的
    /// 都是传统播放器；同时也不改键，舞台页里点「形态」仍走 `.stage()`、
    /// 默认读保存的形态，页内切换的持久化不受影响（播放页顶栏已无舞台
    /// 入口，r20 首页也已去舞台，舞台只从形态选择器进）。
    /// 千万别在这里 `StageCatalog.saveFormId("classic")`：
    /// `isAvailable(classic)` 恒为 false（classic 没有 HTML 文件），
    /// `savedFormId()` 读到 "classic" 会回落到默认 "001"，下次点舞台就
    /// 丢了用户上次用的形态。
    ///
    /// 空态：`track == nil` 时也照常进 `.player`，和单击现有行为一致；
    /// PlayerView 自带空态（标题「未在播放」），不编假数据、不崩。
    private func openClassicPlayer() {
        nav.showClassicPlayer()
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
