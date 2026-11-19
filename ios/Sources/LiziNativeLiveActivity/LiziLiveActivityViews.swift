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
/// - lock screen（r22d 已撤）：原来与展开页同款（封面 + 歌名/歌手 + 进度条 +
///   五个控制），就是用户 04:20 截图里锁屏下面那张黑色卡片——同一个 Live
///   Activity 的锁屏呈现，与灵动岛是同一份 ContentState、不是第二个活动；
///   它的进度 0:17 对不上磨砂卡 2:43，是因为 ContentState.progress 只是
///   App 每 5 秒推一次的快照，锁屏后推送停了就冻住，而磨砂卡是系统
///   MPNowPlayingInfoCenter 的 Now Playing 卡、已播时间由系统按播放速率
///   自己往前走（两张卡同首歌、同 4:00 总时长，0:17 + 3:43 = 2:43 + 1:17）。
///   用户没让加这张卡，要求删掉；磨砂卡（系统 Now Playing）与灵动岛保留。
///   App 侧没有「只留岛、不留锁屏」的公开开关（Apple 要求 Live Activity
///   四种呈现全支持，且不提供按呈现面过滤的 API），唯一能动的手是把
///   ActivityConfiguration 的锁屏闭包换成 EmptyView：岛的三个呈现是独立闭包，
///   不受影响；Now Playing / 封面 / 播放本身一行未动。
///   EmptyView 到底是让系统整个撤掉锁屏横幅、还是留一张空白黑卡，
///   静态验不出来，真机清单 D1 是裁决项——若留空白黑卡，立刻回滚本轮，
///   改走「锁屏只留系统 Now Playing 卡」的兜底（见 verification/r22d-device-checklist.md）。
///   锁屏上的全屏铺满是系统行为：系统拿 MPNowPlayingInfoCenter 的封面画全屏背景；
///   App 只负责把封面供过去，不自己画锁屏。
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

    /// 点岛 → 打开 App 落到正在播放的播放页。
    /// widgetURL 是 View 修饰器，不能挂在 ActivityConfiguration /
    /// DynamicIsland 链上（编包会报 ActivityConfiguration 没有 widgetURL 成员），
    /// 只能挂在岛的各个区域视图的根视图上；控制按钮（Intent/Link）
    /// 自带点按行为，不受它影响。（r22d：锁屏卡片已撤，widgetURL 不再挂锁屏视图。）
    private var nowURL: URL { URL(string: "lizinative://now")! }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiziLyricsAttributes.self) { _ in
            // r22d：锁屏呈现已撤——黑色卡片的来源就是这个闭包（原来调
            // lockScreenView，画封面/歌名/进度条/五个控制，与截图黑卡逐项对得上）。
            // 同一个 Live Activity 在锁屏与灵动岛是两次呈现：删这里只删锁屏那次，
            // DynamicIsland 闭包原样保留，岛的紧凑/最小/展开三态不受影响；
            // 磨砂卡是系统 Now Playing（MPNowPlayingInfoCenter），不在这个扩展里，
            // 删不掉也删不着。EmptyView 是 App 侧唯一能动的手（无按呈现面过滤的
            // 公开 API）；系统是否整条撤掉横幅、还是留空白黑卡，真机 D1 裁决。
            EmptyView()
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
