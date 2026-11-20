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
/// - `isCompact`（r21b 恢复使用）：收小档 = r19 的固定收小尺寸按 tier 等比
///   （单张 × 148/188、轨道 × 198/254；standard 档正好是 r19 的 148/198）。
///   r20 曾把它置为空操作（歌词面板拉起收小改由调用方 scaleEffect 做）；
///   r21b 横屏左列总高只有 306，封面必须用收小档（再 ×0.8），所以恢复。
///   竖屏调用方不传（默认 false），竖屏尺寸与 r20 一字不改。
/// - 滑动方向照抄壳版第 13 轮第 16 件（和首页大卡同一方向）：左滑上一首、
///   右滑下一首；阈值 = 0.3 × 单张边长（标准档 188 → 56.4px，和原来 56px 同感）。
///   上一首直接按队列下标（不走 `previous()` 的
///   “进度 > 3 秒先回开头”分支）；下一首走 `next()`（顺序到底停住、循环回首，
///   和按钮一致）。点两侧封面切歌；点当前封面 = 播放/暂停。
/// - r23j（滑动按封面大小定，用户原话「滑动效果要按封面大小定，不然太突兀」）：
///   静态偏移早已按边长等比，但滑动是死的——阈值写死 56、只有 onEnded、松手
///   0.38s 定长动画跳过去，大封面跳得突兀。改法：① onChanged 跟手，进度 =
///   dx / itemSize，偏移/旋转/缩放按进度在相邻两档 metrics 间插值（有效档位
///   = offset − progress：右滑时下一首（+1 档）向中央靠，松手切歌正好到位，
///   不跳变；方向映射不变，左滑上一首、右滑下一首）；② 阈值 = 0.3 × itemSize；
///   ③ 松手动画时长 = 单档时长 × 实际滑距（档），单档时长 = 0.38 × itemSize / 188
///   （标准档一档仍是 0.38s，大封面相应变长），回弹按 |progress| 档、切歌按
///   剩余 (1 − |progress|) 档，最短 0.12s 兜底；④ 方向横屏竖屏一样
///   （itemSize 只随 tier/isCompact 变，与朝向无关）。
///
/// 诚实注：SwiftUI 的 `rotation3DEffect(perspective:)` 没有 CSS `perspective: 1100px`
/// 的精确等价换算；这里用 perspective 0.5 + 按 CSS 透视公式算出的缩放
/// （scale = 1100 / (1100 + |translateZ|)，即 -110 → 0.91、-200 → 0.85）
/// 来还原纵深感，真机上如觉透视过强/过弱只改 `perspective3D` 一个值。
struct CoverFlowView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 收小档（r21b 恢复使用，见文件头）：true 时单张 × 148/188、轨道 × 198/254
    ///（standard 档 = r19 的 148/198）；横屏左列用它。竖屏默认 false。
    var isCompact: Bool = false
    /// 点队列行切歌以外的切歌回调（默认直接调 store；调用方一般不用传）。
    var onSelectIndex: ((Int) -> Void)? = nil

    /// SwiftUI 透视系数（近似 CSS perspective: 1100px，见文件头注释）。
    private static let perspective3D: CGFloat = 0.5
    /// 滑动切歌阈值占比（r23j：0.3 × 单张边长，取代写死 56px；
    /// 标准档 188 → 56.4px，和原来 56px 同感；大封面 208 → 62.4px，
    /// 小封面 168 → 50.4px，收小档再 ×148/188）。
    private static let swipeThresholdFraction: CGFloat = 0.3
    /// 拖动跟手进度（r23j）：dx / itemSize，夹到 ±1 档；手指停封面就停，
    /// 不挂动画修饰符。
    @State private var dragProgress: CGFloat = 0
    /// 松手动画时长（r23j）：切歌/回弹前按实际滑距算好存在这里，
    /// `.animation(..., value: store.currentIndex)` 用它动画下标切换。
    /// 初始 0.38s 是标准档参考值，onAppear 按实际 itemSize 纠正。
    @State private var snapDuration: Double = 0.38

    /// 松手切歌时下标切换也走 `.onChange(of: currentIndex)`；这个 flag 告诉
    /// onChange：本次切换的 snapDuration 已按剩余路程算好，别重置回整档时长。
    /// （next() 在顺序到底时可能不换下标、onChange 不触发，flag 会多留一轮，
    /// 后果只是一次外面切歌沿用上次时长，无其他影响。）
    @State private var holdReleaseDuration = false

    /// 滑动切歌阈值 = 0.3 × 单张边长（r23j，见 swipeThresholdFraction）。
    private var swipeThreshold: CGFloat { itemSize * Self.swipeThresholdFraction }
    /// 单档时长（r23j）：标准档（边长 188）一档 0.38s，时长随边长等比缩放——
    /// 大封面滑得远、时间相应变长，小封面反之。
    private var stepDuration: Double { 0.38 * Double(itemSize) / 188 }
    /// 松手动画时长（r23j）：按实际滑距（travelSteps 档，0…1）走，
    /// 最短 0.12s 兜底（路程极短时不至于快到看不见）。
    private func releaseDuration(travelSteps: CGFloat) -> Double {
        max(0.12, stepDuration * Double(max(0, min(1, travelSteps))))
    }

    private var itemSize: CGFloat {
        isCompact ? PlayerTokens.coverItem(tier) * 148 / 188 : PlayerTokens.coverItem(tier)
    }

    private var trackHeight: CGFloat {
        isCompact ? PlayerTokens.coverTrackHeight(tier) * 198 / 254 : PlayerTokens.coverTrackHeight(tier)
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
        .onAppear { snapDuration = stepDuration }
        .onChange(of: store.currentIndex) { _ in
            // 外面切歌（播完自动下一首、控制行按钮）时拖动进度清零，
            // 免得残留的 dragProgress 把新下标的封面顶偏；同时把动画时长
            // 重置回整档时长（stepDuration ∝ itemSize）。松手切歌那次不重置，
            // snapDuration 已按剩余路程算好（见 holdReleaseDuration）。
            dragProgress = 0
            if holdReleaseDuration {
                holdReleaseDuration = false
            } else {
                snapDuration = stepDuration
            }
        }
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
                // 点两侧切歌：一整档，时长按边长走（stepDuration ∝ itemSize）。
                snapDuration = stepDuration
                withAnimation(.easeOut(duration: stepDuration)) { select(index: index) }
            }
        }
        // r23j：松手/点按的动画时长不再定死 0.38s，用松手前按实际滑距算好的 snapDuration。
        .animation(.easeOut(duration: snapDuration), value: store.currentIndex)
    }

    // MARK: - 变换表（照抄 app.css .cf__item[data-off]，偏移按边长等比）

    private struct Metrics {
        var offsetX: CGFloat
        var scale: CGFloat
        var rotateY: Double
        var opacity: Double
    }

    /// 拖动跟手（r23j）：有效档位 = offset − dragProgress，在相邻两档 metrics 间插值。
    /// 右滑 progress > 0 时下一首（+1 档）向中央靠、当前张向 −1 档靠，松手切歌正好到位；
    /// 左滑反之。必须是减号：加号会让目标首离中央越来越远，松手切歌时跳一整档以上，
    /// 正是用户说的突兀。手指停（progress 不变）封面就停。
    private func metrics(for offset: Int) -> Metrics {
        metrics(forEffectiveOffset: Double(offset) - Double(dragProgress))
    }

    /// 在相邻两档之间线性插值（偏移/缩放/旋转/透明度四项都插）；有效档位夹到 ±2，
    /// 最外侧一张拖到头不再外移。
    private func metrics(forEffectiveOffset effective: Double) -> Metrics {
        let clamped = min(2, max(-2, effective))
        let lo = Int(floor(clamped))
        let hi = min(2, lo + 1)
        let f = clamped - Double(lo)
        let a = baseMetrics(for: lo)
        let b = baseMetrics(for: hi)
        return Metrics(
            offsetX: a.offsetX + (b.offsetX - a.offsetX) * CGFloat(f),
            scale: a.scale + (b.scale - a.scale) * CGFloat(f),
            rotateY: a.rotateY + (b.rotateY - a.rotateY) * f,
            opacity: a.opacity + (b.opacity - a.opacity) * f
        )
    }

    private func baseMetrics(for offset: Int) -> Metrics {
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
            .onChanged { value in
                // r23j 跟手：进度 = dx / itemSize，夹到 ±1 档（一次只滑一首）。
                // 这里不加动画——dragProgress 没挂 .animation 修饰符，手指停封面就停。
                dragProgress = max(-1, min(1, value.translation.width / itemSize))
            }
            .onEnded { value in
                let dx = value.translation.width
                let progress = dx / itemSize
                guard store.queue.count >= 2 else {
                    // 只有一首：无处可切，直接回弹。
                    let duration = releaseDuration(travelSteps: abs(progress))
                    snapDuration = duration
                    withAnimation(.easeOut(duration: duration)) { dragProgress = 0 }
                    return
                }
                if abs(dx) > swipeThreshold {
                    // 切歌：剩余路程 (1 − |progress|) 档，时长按剩余路程走；
                    // 有效档位 = offset − progress，松手时目标首离中央只剩
                    // (1 − |progress|) 档，dragProgress 清零 + 下标切换在同一
                    // 事务里动画到位，不跳变。
                    let duration = releaseDuration(travelSteps: 1 - min(1, abs(progress)))
                    snapDuration = duration
                    withAnimation(.easeOut(duration: duration)) {
                        dragProgress = 0
                        if dx < 0 {
                            // 左滑上一首：直接按队列下标（不走 previous() 的回开头分支）。
                            let prev = (store.currentIndex - 1 + store.queue.count) % store.queue.count
                            select(index: prev)
                        } else {
                            // 右滑下一首：走 next()，和按钮一致。
                            store.next()
                        }
                        // 告诉 onChange：这次下标切换的时长已按剩余路程算好，别重置。
                        holdReleaseDuration = true
                    }
                } else {
                    // 没过阈值：回弹，路程 |progress| 档，时长按回弹路程走。
                    let duration = releaseDuration(travelSteps: abs(progress))
                    snapDuration = duration
                    withAnimation(.easeOut(duration: duration)) { dragProgress = 0 }
                }
            }
    }

    private func select(index: Int) {
        if let onSelectIndex {
            onSelectIndex(index)
        } else if store.queue.indices.contains(index) {
            // r25-B4：按 queueId 播（U6 同根：play(track) 只按 id+platform
            // 找第一个匹配项，队列有重复曲目时点第几行会播成第一行）。
            store.play(queueItem: store.queue[index])
        }
    }
}
