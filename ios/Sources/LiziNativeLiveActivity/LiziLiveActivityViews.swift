import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity for Lizi: 岛上长这样（第 12 轮第 15 件，按用户 03:41 两张
/// 目标截图重做，照 Apple Music 的岛）：
/// - compact（紧凑胶囊）：左边专辑封面缩略图，右边白色音频波形（均衡器）。
///   没有歌词行——截图目标就是这样；第 22 轮第 5 件：ContentState 里已无歌词
///   字段（用户不要岛上歌词），岛更新只剩切歌、播放切换、喜欢态、5 秒进度四路。
/// - expanded（点开）：左上封面大图，右边歌名+歌手，右上波形；下面进度条
///   （已播 / 剩余，m:ss）；最下面一排控制：星标（喜欢）、上一首、暂停/播放、
///   下一首、AirPlay。控制按钮走 LiveActivityIntent（App 进程内执行，不打开 App，
///   iOS 17.2+；16.2–17.1 上只显示图标、点不了）。
/// - AirPlay：第三方 Live Activity 里放不了 AVRoutePickerView（UIKit 视图，
///   Widget 只支持纯 SwiftUI），也没有公开 API 能在岛上原地弹出系统路由面板；
///   所以 AirPlay 是 Link 到 lizinative://airplay——打开 App 并直接弹出系统路由选择页
///   （AVRoutePickerView，点它出系统设备列表 + 音量条），不是点着没反应的图标。
///   锁屏系统播放器自带的 AirPlay 按钮是系统画的，不用 App 管。
/// - 点胶囊非按钮区：widgetURL lizinative://now，打开 App 落到正在播放的那首歌的
///   播放页（按上次的形态进）；点展开页里的控制按钮是各自的功能，不跳 App。
/// - minimal: ♪。
/// - lock screen（r27 恢复）：毛玻璃播放卡，按用户 23:30 Apple Music
///   锁屏截图定稿（Taylor Swift《The Woods (Taylor's Version)》）：
///   歌名居中、歌手居中在下、进度条（左已播、右剩余）、控制行
///   爱心 / 上一首 / 暂停 / 下一首 / AirPlay。唯一改动：左起第一位是
///   爱心不是五角星——系统 Now Playing 磨砂卡上的星标是 iOS 画的、App
///   换不掉，爱心只能出在我们自己的 Live Activity 锁屏视图里（这张卡）。
///   同一个 Live Activity 的锁屏呈现，与灵动岛是同一份 ContentState、
///   不是第二个活动；全屏专辑背景是系统行为（系统拿
///   MPNowPlayingInfoCenter 的封面画），App 不自己画锁屏背景。
///   r22d 曾把这里换成 EmptyView（用户当时要删的是它下面那张黑卡）；
///   r22 黑卡的根因是旧 lockScreenView（壳版同款）全程没有任何
///   .background——容器默认底色是黑的。r27 防黑卡三点都落实在
///   lockScreenView 里（内容、背景、尺寸），见该函数头的注释。
///   恢复后锁屏上是否只剩这一张卡、还是系统磨砂卡也同时在（r22 时两张卡
///   同时出现过），静态验不出来，真机裁决；若两张卡并存，由用户定去留，
///   不要私自换回 EmptyView。
///   进度仍是 ContentState 的 5 秒快照：锁屏后推送停了进度会冻住，与
///   系统磨砂卡实时走的进度对不上是已知行为，不是 bug。
struct LiziLiveActivity: Widget {
    /// 封面图（有就画，没就画默认音符，不留空白）。
    @ViewBuilder
    private func coverArt(_ data: Data?, size: CGFloat, corner: CGFloat) -> some View {
        if let data, let ui = UIImage(data: data) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner))
        } else {
            Text("♪")
                .font(.system(size: size * 0.6))
                .frame(width: size, height: size)
        }
    }

    /// 白色音频波形（均衡器竖条，照 03:41 紧凑截图右边的样子画；
    /// 不用 SF Symbol，静态竖条在各版本上长得一样）。
    private func waveformView(height: CGFloat = 16) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 3, height: height * 0.45)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 3, height: height)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 3, height: height * 0.65)
            RoundedRectangle(cornerRadius: 1)
                .frame(width: 3, height: height * 0.85)
        }
        .foregroundStyle(.white)
    }

    /// 秒 → m:ss（进度条两端的时间）。
    private func mmss(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// 进度行：已播时间 + 进度条 + 剩余时间（带负号，如 -2:24）。
    private func progressRow(context: ActivityViewContext<LiziLyricsAttributes>) -> some View {
        let duration = context.state.duration
        let elapsed = duration > 0 ? context.state.progress * duration : 0
        let remaining = duration > 0 ? max(0, duration - elapsed) : 0
        return HStack(spacing: 8) {
            Text(mmss(elapsed))
                .font(.caption2)
                .foregroundStyle(.secondary)
            ProgressView(value: context.state.progress)
                .tint(.white)
            Text("-" + mmss(remaining))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// 控制行：星标（喜欢）、上一首、暂停/播放、下一首、AirPlay。
    /// 锁屏控制行另见 lockScreenControlButtons（爱心版，同样的 Intent 机制）。
    /// 前四个走 LiveActivityIntent（iOS 17.2+，不打开 App）；AirPlay 是
    /// Link 到 lizinative://airplay（见文件头注释：原地弹系统面板没有公开 API）。
    @ViewBuilder
    private func controlButtons(context: ActivityViewContext<LiziLyricsAttributes>) -> some View {
        HStack(spacing: 30) {
            if #available(iOS 17.2, *) {
                Button(intent: LiziIslandControlIntent(action: .toggleLike)) {
                    Image(systemName: context.state.isLiked ? "star.fill" : "star")
                        .font(.system(size: 20))
                }
                Button(intent: LiziIslandControlIntent(action: .previous)) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                }
                Button(intent: LiziIslandControlIntent(action: .togglePlay)) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                }
                Button(intent: LiziIslandControlIntent(action: .next)) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                }
            } else {
                Image(systemName: context.state.isLiked ? "star.fill" : "star")
                    .font(.system(size: 20))
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
            }
            Link(destination: URL(string: "lizinative://airplay")!) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 20))
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    /// 锁屏毛玻璃播放卡（r27：按用户 23:30 Apple Music 锁屏截图定稿恢复；
    /// r22d 曾把它换成 EmptyView，用户当时要删的是它下面那张黑卡）。
    /// 画法照参考图（Taylor Swift《The Woods (Taylor's Version)》）：
    /// 歌名居中大字、歌手居中在下、进度条（左已播、右剩余）、控制行
    /// 爱心 / 上一首 / 暂停 / 下一首 / AirPlay 一字排开。
    /// 与参考图唯一的区别：左起第一位是爱心不是五角星——系统 Now Playing
    /// 磨砂卡上的星标是 iOS 画的、App 换不掉，爱心只能出在我们自己的
    /// Live Activity 锁屏视图里（这张卡）。
    ///
    /// r22 的 D1 教训——为什么这次不会再出黑卡（内容、背景、尺寸三点都落实）：
    /// 1. 内容：卡里永远有东西——歌名/歌手走 attributes（非空 String，
    ///    起岛时就有）、进度行与控制行无条件画（duration 为 0 时画 0:00 /
    ///    -0:00，不留空）；旧版黑卡的根因之一是同一份视图既没背景也没
    ///    兜底，内容一空就只剩一张黑底。
    /// 2. 背景：显式 .ultraThinMaterial（毛玻璃，照参考图的磨砂卡）画在
    ///    圆角矩形里，不依赖系统给锁屏呈现的默认容器底色——r22 黑卡就是
    ///    因为旧 lockScreenView（壳版同款，见 LiziLiveActivityViews.swift）
    ///    全程没有任何 .background，容器默认底色是黑的。
    /// 3. 尺寸：.frame(maxWidth: .infinity, minHeight: 168)，卡片宽度撑满
    ///    锁屏、高度有下限，不会出现 0 高/塌成一条线的空壳。
    /// 封面不画进卡里：全屏专辑背景是系统行为（系统拿
    /// MPNowPlayingInfoCenter 的封面画），App 不自己画锁屏背景，
    /// 动态封面路线 A 的供图链路本轮一个字没动。
    /// 进度仍是 ContentState 的 5 秒快照（见文件头）：锁屏后推送停了进度
    /// 会冻住，与系统磨砂卡实时走的进度对不上是已知行为，不是 bug。
    /// 诚实边界：恢复锁屏呈现后，锁屏上是否只剩这一张卡、还是系统
    /// Now Playing 磨砂卡也同时在（r22 时两张卡同时出现过），静态验不出来，
    /// 真机裁决；若两张卡并存，由用户定去留，不要私自再把锁屏闭包换回 EmptyView。
    private func lockScreenView(context: ActivityViewContext<LiziLyricsAttributes>) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(context.attributes.title)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(context.attributes.artist)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            progressRow(context: context)
            lockScreenControlButtons(context: context)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 168)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .widgetURL(nowURL)
    }

    /// 锁屏控制行：爱心 / 上一首 / 暂停 / 下一首 / AirPlay（照参考图一字排开，
    /// 暂停键最大居中）。爱心与展开页星标是同一个喜欢态、同一个 Intent：
    /// 读 ContentState.isLiked（已喜欢实心、未喜欢空心），点按走
    /// LiziIslandControlIntent(.toggleLike) → IslandControlRelay →
    /// PlaybackStore.toggleLike（App 进程内执行，不打开 App，iOS 17.2+；
    /// 16.2–17.1 上只显示图标、点不了，与展开页同款降级）。
    /// 不另起喜欢逻辑、不读任何共享存储：原生版没有 App Group，扩展只能
    /// 从 ContentState 拿喜欢态；App 侧 NativeIslandCoordinator 已在
    /// $isLiked 变化与切歌时立刻推新 state（见 snapshot 里 isLiked:
    /// store.isLiked），点按翻转后 App 推回新态，爱心实心/空心跟随。
    /// AirPlay 与展开页同款：Link 到 lizinative://airplay，打开 App 弹系统路由页。
    @ViewBuilder
    private func lockScreenControlButtons(context: ActivityViewContext<LiziLyricsAttributes>) -> some View {
        HStack {
            if #available(iOS 17.2, *) {
                Button(intent: LiziIslandControlIntent(action: .toggleLike)) {
                    Image(systemName: context.state.isLiked ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                }
                Spacer()
                Button(intent: LiziIslandControlIntent(action: .previous)) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 22))
                }
                Spacer()
                Button(intent: LiziIslandControlIntent(action: .togglePlay)) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34))
                }
                Spacer()
                Button(intent: LiziIslandControlIntent(action: .next)) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 22))
                }
                Spacer()
            } else {
                Image(systemName: context.state.isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 20))
                Spacer()
                Image(systemName: "backward.fill")
                    .font(.system(size: 22))
                Spacer()
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34))
                Spacer()
                Image(systemName: "forward.fill")
                    .font(.system(size: 22))
                Spacer()
            }
            Link(destination: URL(string: "lizinative://airplay")!) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 20))
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.plain)
    }

    /// 点岛 → 打开 App 落到正在播放的播放页。
    /// widgetURL 是 View 修饰器，不能挂在 ActivityConfiguration /
    /// DynamicIsland 链上（编包会报 ActivityConfiguration 没有 widgetURL 成员），
    /// 只能挂在岛的各个区域视图与锁屏卡片的根视图上；控制按钮（Intent/Link）
    /// 自带点按行为，不受它影响。（r27：锁屏卡片恢复，widgetURL 也挂锁屏卡片根视图；
    /// 点卡片非按钮区进播放页。）
    private var nowURL: URL { URL(string: "lizinative://now")! }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiziLyricsAttributes.self) { context in
            // r27：锁屏呈现恢复——调 lockScreenView 画毛玻璃播放卡（爱心版，
            // 见该函数头的 D1 教训注释）。同一个 Live Activity 在锁屏与灵动岛
            // 是两次呈现：这里只管锁屏那次，DynamicIsland 闭包原样保留，
            // 岛的紧凑/最小/展开三态不受影响；系统 Now Playing 磨砂卡不在
            // 这个扩展里，删不掉也改不着——两张卡是否并存，真机 D1 裁决。
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    coverArt(context.state.coverData, size: 52, corner: 10)
                        .widgetURL(nowURL)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    waveformView(height: 16)
                        .widgetURL(nowURL)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .widgetURL(nowURL)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        progressRow(context: context)
                        controlButtons(context: context)
                    }
                    .widgetURL(nowURL)
                }
            } compactLeading: {
                coverArt(context.state.coverData, size: 28, corner: 6)
                    .widgetURL(nowURL)
            } compactTrailing: {
                waveformView(height: 14)
                    .widgetURL(nowURL)
            } minimal: {
                Text("♪")
            }
            .keylineTint(.white)
        }
    }
}
