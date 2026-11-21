import SwiftUI

/// 「下一首播放」长按菜单（r31）：歌曲行共用的唯一入口。
///
/// iOS 上长按出菜单 = SwiftUI `.contextMenu`；菜单里只有「下一首播放」
/// 一项，点一下调 `PlaybackStore.playNext(_:)` 真插队——插到当前曲目
/// 之后、已排的下一首块之后，当前播完就播它；不是只摆个菜单项架子。
///
/// 7 个平台不设守卫：插队只动队列，取链/播放在起播时按曲目 platform
/// 走原有 resolveURL 编排（netease / qq / kugou / qishui / bodian /
/// kuwo / applemusic 全都走同一条插队路）。
///
/// 不挂 3D 环卡：环卡已有自定义长按/拖动手势，r23 的教训是同一根触摸
/// 上不叠 highPriority / sequenced / 长按识别器，会死锁；环卡的下一首
/// 入口等环工把手势理顺后再接，这里不抢。
///
/// r31-download：菜单里加「下载歌曲」一项，点按弹 DownloadOptionsSheet
///（选音质：默认档 + 探可用档 + 不支持自动降级），不是只摆个菜单项架子。
struct PlayNextMenuModifier: ViewModifier {
    @EnvironmentObject private var playback: PlaybackStore
    let track: Track
    @State private var showDownloadOptions = false

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                playback.playNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.insert")
            }
            .accessibilityLabel("下一首播放 \(track.title)")
            Button {
                showDownloadOptions = true
            } label: {
                Label("下载歌曲", systemImage: "arrow.down.to.line")
            }
            .accessibilityLabel("下载歌曲 \(track.title)")
        }
        .sheet(isPresented: $showDownloadOptions) {
            DownloadOptionsSheet(tracks: [track])
        }
    }
}

extension View {
    /// 给任意歌曲行挂「下一首播放」长按菜单。
    /// 挂在 `TrackRowView` 上：搜索结果、歌单详情、歌手页、专辑页、
    /// 榜单详情六处共用同一行视图，一处挂上六处都有入口。
    /// r31-download：「下载歌曲」同挂这里，六处行菜单都有下载入口。
    func playNextMenu(track: Track) -> some View {
        modifier(PlayNextMenuModifier(track: track))
    }
}
