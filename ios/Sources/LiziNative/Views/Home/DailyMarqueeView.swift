import SwiftUI

/// 每日推荐跑马带：横向自动滚动歌曲卡，点一首直接播。
///
/// r28 注：本视图自 r21 起未再挂载（HomeView 用 HomeCoverRingView 的
/// 平面带当每日卡行，两处并存会叠两条一样的带），只留作备用；数值与
/// HomeCoverRingView 的平面带保持同步（卡宽、字号、松手恢复见下）。
///
/// 照抄壳版 `.hall-marq`：
/// - 卡 156 宽、间距 16；首卡贴左、无半切（左内边距 0）。
/// - 自动滚动：默认慢速（HomeViewModel.marqSpeedPxPerSecond，默认 24 → 24 px/s）；
///   回卷 / 初画时在最左停 2.5 秒再走（壳版 marqDwellUntil），首卡看得见、定得住。
/// - 内容复制两份循环：滚过一份宽度就无缝回卷。
/// - 可横向拖动：拖动时暂停自动滚动，松手 1.2 秒后恢复（r28：39.6s 视频
///   规格松手 1200ms 后恢复，旧 1 秒已改）；竖向滚动走
///   simultaneousGesture，不抢页面的竖滑。
/// - 点卡：setQueue(整份每日推荐, startAt: 下标)——setQueue 内部已播该首，
///   不用再调一次 play。
struct DailyMarqueeView: View {
    let tracks: [DailyTrack]
    let isLoading: Bool
    let emptyReason: String?
    let speedPxPerSecond: CGFloat
    let onPlay: (Int) -> Void

    @State private var offsetX: CGFloat = 0
    @State private var setWidth: CGFloat = 0
    @State private var isDragging = false
    @State private var dragBase: CGFloat = 0
    @State private var dwellUntil = Date().addingTimeInterval(2.5)

    // r31-120hz：Timer 驱动的动画帧率——旧 1/30（30Hz）步进 0.8px 肉眼一顿一顿；
    // 改 1/120，步长同步改 /120.0（速度不变）；Timer 不是 vsync 同步，120Hz 机型
    // 仍可能抖动，本视图自 r21 起未挂载（备用），真要重新挂载应改 CADisplayLink。
    private let timer = Timer.publish(every: 1.0 / 120.0, on: .main, in: .common).autoconnect()

    /// r35-9（P0-2）：spinner 延迟显示（套壳 250ms 保留旧内容同款）——
    /// 加载开始先保留旧内容，250ms 后仍未回来才亮 spinner；250ms 内
    /// 回来全程不闪。`.task(id: isLoading)` 管：isLoading 翻 true 时
    /// 睡 250ms 再亮，翻 false 时任务取消重跑、直接灭。
    @State private var showSpinner = false

    var body: some View {
        Group {
            if !tracks.isEmpty {
                // 有旧内容时直接留旧内容，加载中也不切走（套壳同款）。
                marqueeContent
            } else if isLoading {
                if showSpinner {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在拉取每日推荐…")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.ink3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
                } else {
                    // 250ms 内还没回来：旧内容没有，也不亮 spinner，
                    // 只留空白占位，不闪「暂无推荐内容」。
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
                }
            } else {
                Text(emptyReason ?? "暂无推荐内容。")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 195, alignment: .center)
                    .padding(.horizontal, 24)
            }
        }
        .onReceive(timer) { _ in tick() }
        .task(id: isLoading) {
            if isLoading {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    // 250ms 内加载完了（任务被取消），不亮 spinner。
                    return
                }
                showSpinner = true
            } else {
                showSpinner = false
            }
        }
        .onChange(of: tracks.map { $0.id }) { _ in
            // 数据换了：回到最左，停 2.5 秒再走（壳版回卷行为）。
            offsetX = 0
            dwellUntil = Date().addingTimeInterval(2.5)
        }
    }

    private var marqueeContent: some View {
        HStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 16) {
                    ForEach(tracks.indices, id: \.self) { i in
                        MarqueeCard(track: tracks[i].track) {
                            onPlay(i)
                        }
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: geo.size.width)
                    }
                )
            }
        }
        .offset(x: offsetX)
        .onPreferenceChange(MarqueeWidthKey.self) { width in
            // 一份宽度 + 一份间距（两份之间的 16 间距也要算进回卷步长）。
            setWidth = width + 16
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragBase = offsetX
                    }
                    offsetX = normalized(dragBase + value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                    dwellUntil = Date().addingTimeInterval(1.2)
                }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func tick() {
        guard !tracks.isEmpty, setWidth > 0, !isDragging, Date() >= dwellUntil else { return }
        offsetX = normalized(offsetX - speedPxPerSecond / 120.0)
    }

    /// 把偏移收进 (-setWidth, 0]，保证两份循环无缝。
    private func normalized(_ x: CGFloat) -> CGFloat {
        guard setWidth > 0 else { return x }
        var v = x
        while v > 0 { v -= setWidth }
        while v <= -setWidth { v += setWidth }
        return v
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 跑马带里的一张卡：封面 + 歌名 + 歌手（壳版 .marq__card：156 宽）。
private struct MarqueeCard: View {
    let track: Track
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                // r49: 白占位改深色——与 CoverImageView 同款 DefaultCoverArt（环内深色占位一致）。
                ProxyImageView(url: track.coverURL) { DefaultCoverArt(iconSize: 64) }
                .frame(width: 156, height: 156)
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
            .frame(width: 156, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
