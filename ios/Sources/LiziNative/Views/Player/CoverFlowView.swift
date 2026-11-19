import SwiftUI

/// 3D 封面流（播放页上半部分），数值照抄壳版 `app.css` 的 `.cf` 一套：
///
/// - 透视 1100；单张圆角 14、下方倒影（`below 8px`，沿用 `CoverReflectionView`）。
/// - 当前张居中放大 1.04；两侧按单张边长等比偏移（标准档 ±128px / ±224px，
///   即边长 × 128/188、× 224/188）、rotateY ±40°/±50°、translateZ -110/-200、
///   透明度 0.88/0.5，共显示 5 张。
/// - 尺寸走分档（r20）：单张边长 `PlayerTokens.coverItem(tier)`、轨道高
///   `PlayerTokens.coverTrackHeight(tier)`；轨道高含倒影（单张 + 间距 8 +
///   倒影 单张 × 0.3，见 `PlayerTokens` 总账注释）。
/// - r20 删掉了歌词面板拉起收小那套（旧 `coverFlowItemSizeCompact` /
///   `coverFlowTrackHeightCompact` 已随旧常量删除）：封面流尺寸只由 tier
///   决定，不再随面板展开态变化。`isCompact` 参数仅作兼容保留（默认值
///   false），调用方不要再传它；它不参与任何尺寸计算。
/// - 滑动方向照抄壳版第 13 轮第 16 件（和首页大卡同一方向）：左滑上一首、
///   右滑下一首；阈值 56px。上一首直接按队列下标（不走 `previous()` 的
///   “进度 > 3 秒先回开头”分支）；下一首走 `next()`（顺序到底停住、循环回首，
///   和按钮一致）。点两侧封面切歌；点当前封面 = 播放/暂停。
///
/// 诚实注：SwiftUI 的 `rotation3DEffect(perspective:)` 没有 CSS `perspective: 1100px`
/// 的精确等价换算；这里用 perspective 0.5 + 按 CSS 透视公式算出的缩放
/// （scale = 1100 / (1100 + |translateZ|)，即 -110 → 0.91、-200 → 0.85）
/// 来还原纵深感，真机上如觉透视过强/过弱只改 `perspective3D` 一个值。
struct CoverFlowView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 兼容保留：r20 起不再参与尺寸计算（歌词面板拉起收小的逻辑已删），
    /// 调用方不要再传它；留着只为不断旧调用点的编译。
    var isCompact: Bool = false
    /// 点队列行切歌以外的切歌回调（默认直接调 store；调用方一般不用传）。
    var onSelectIndex: ((Int) -> Void)? = nil

    /// SwiftUI 透视系数（近似 CSS perspective: 1100px，见文件头注释）。
    private static let perspective3D: CGFloat = 0.5
    /// 滑动切歌阈值（壳版 bindCoverFlow：56px）。
    private static let swipeThreshold: CGFloat = 56

    private var itemSize: CGFloat {
        PlayerTokens.coverItem(tier)
    }

    private var trackHeight: CGFloat {
        PlayerTokens.coverTrackHeight(tier)
    }

    /// 显示的 5 个位置：相对当前下标的偏移 -2…+2（队首/队尾处自然变少，不补假数据）。
    private var visibleOffsets: [Int] {
        guard store.currentIndex >= 0, !store.queue.isEmpty else { return [0] }
        return (-2...2).filter { store.queue.indices.contains(store.currentIndex + $0) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(visibleOffsets, id: \.self) { offset in
                coverItem(offset: offset)
                    .zIndex(zIndex(for: offset))
            }
        }
        .frame(height: trackHeight)
        .contentShape(Rectangle())
        .gesture(swipeGesture)
    }

    // MARK: - 单张封面

    @ViewBuilder
    private func coverItem(offset: Int) -> some View {
        let index = store.currentIndex + offset
        let track = store.queue.indices.contains(index) ? store.queue[index].track : nil
        let metrics = metrics(for: offset)

        VStack(spacing: 8) {
            CoverImageView(url: track?.coverURL, placeholderIconSize: 64)
                .frame(width: itemSize, height: itemSize)
                .clipShape(RoundedRectangle(cornerRadius: PlayerTokens.radiusMd))
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 18)
                .overlay(
                    // 当前张播放时轻微放大提示（壳版 body.is-now .disc.is-playing scale(1.02)）。
                    RoundedRectangle(cornerRadius: PlayerTokens.radiusMd)
                        .stroke(Color.white.opacity(0.14), lineWidth: offset == 0 ? 1 : 0)
                )
            CoverReflectionView(url: track?.coverURL, height: itemSize * 0.3)
                .frame(width: itemSize)
        }
        .frame(width: itemSize)
        .opacity(metrics.opacity)
        .scaleEffect(metrics.scale)
        .rotation3DEffect(
            .degrees(metrics.rotateY),
            axis: (x: 0, y: 1, z: 0),
            perspective: Self.perspective3D
        )
        .offset(x: metrics.offsetX)
        .onTapGesture {
            if offset == 0 {
                store.togglePlay()
            } else if store.queue.indices.contains(index) {
                select(index: index)
            }
        }
        .animation(.easeOut(duration: 0.38), value: store.currentIndex)
    }

    // MARK: - 变换表（照抄 app.css .cf__item[data-off]，偏移按边长等比）

    private struct Metrics {
        var offsetX: CGFloat
        var scale: CGFloat
        var rotateY: Double
        var opacity: Double
    }

    private func metrics(for offset: Int) -> Metrics {
        // 侧张横向偏移：标准档 128/224（边长 188）；按边长等比缩放，
        // compact 168 → 114/200，large 208 → 142/248。
        let step1: CGFloat = itemSize * 128 / 188
        let step2: CGFloat = itemSize * 224 / 188
        // translateZ 的透视缩放：scale = 1100 / (1100 + |z|)。
        // -110 → 0.91、-200 → 0.85（各档同值，不随 tier 变）。
        let z1: CGFloat = 110
        let z2: CGFloat = 200
        switch offset {
        case 0:
            return Metrics(offsetX: 0, scale: 1.04, rotateY: 0, opacity: 1)
        case -1:
            return Metrics(offsetX: -step1, scale: 1100 / (1100 + z1), rotateY: 40, opacity: 0.88)
        case 1:
            return Metrics(offsetX: step1, scale: 1100 / (1100 + z1), rotateY: -40, opacity: 0.88)
        case -2:
            return Metrics(offsetX: -step2, scale: 1100 / (1100 + z2), rotateY: 50, opacity: 0.5)
        case 2:
            return Metrics(offsetX: step2, scale: 1100 / (1100 + z2), rotateY: -50, opacity: 0.5)
        default:
            return Metrics(offsetX: 0, scale: 1, rotateY: 0, opacity: 0)
        }
    }

    private func zIndex(for offset: Int) -> Double {
        switch abs(offset) {
        case 0: return 5
        case 1: return 4
        default: return 3
        }
    }

    // MARK: - 手势（滑动切歌；点按走各张自己的 onTapGesture）

    private var swipeGesture: some Gesture {
        // minimumDistance 8：8px 内死区，点按不被拖动抢走（壳版 pointermove 同款死区）。
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > Self.swipeThreshold, store.queue.count >= 2 else { return }
                if dx < 0 {
                    // 左滑上一首：直接按队列下标（不走 previous() 的回开头分支）。
                    let prev = (store.currentIndex - 1 + store.queue.count) % store.queue.count
                    select(index: prev)
                } else {
                    // 右滑下一首：走 next()，和按钮一致。
                    store.next()
                }
            }
    }

    private func select(index: Int) {
        if let onSelectIndex {
            onSelectIndex(index)
        } else if store.queue.indices.contains(index) {
            store.play(store.queue[index].track)
        }
    }
}
