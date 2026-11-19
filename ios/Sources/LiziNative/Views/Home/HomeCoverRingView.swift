import SwiftUI

/// 首页 3D 封面环（r20）：壳版首页下半区那个环的原生版。
///
/// 壳版证据（先查壳版再动手）：
/// - 位置：手机壳 `public/m/index.legacy.html:127-136`——首页下半区
///   `<section class="ringsec">`，在上半张大封面（上半天 1:1 cover）与
///   平台行 / 来源行（`.navstage`，见同文件 :117-125）之下，是首页的
///   最后一块；桌面壳同款在 `#hall-plat` 里平台长条之下的 `#hall-marq`
///  （`public/index.html`，由 `hall/circular-carousel.js` 接管）。
///   原生首页的对应位置就是 Hero 大卡 → 平台条 → 来源 chips 之后、
///   每日推荐 / rails 之前——本文件只管环本身，接入点见 `HomeView`。
/// - 内容：`public/m/m.js:578-590 ringItems()`——环里是当前来源的条目
///   `S.items`（默认来源 `daily` 每日推荐，`m.js:144`；上限 60 首，
///   `applyResult` 里 `ring.setItems(ringItems())`）；点卡片播歌是
///   `onRingPlay`（`m.js:2566`）→ `playIndex`（`m.js:646`）→
///   `Player.playQueue(items, i, true)`：整份列表进队列、从点中的起播。
///   原生映射（不编数据源）：队列非空时环就是播放队列
///   （`PlaybackStore.queue` / `currentIndex`，点一张卡播完后队列与环
///   内容本来就是同一份）；队列为空（还没播过）时环是每日推荐
///   （`dailyTracks`，默认来源 daily，与壳版一致），点/滑一下就整份
///   `setQueue` 进队列、从该首起播——和壳版 `playQueue(items, i)` 同款。
///   两份都空时环整个不显示（`tracks.isEmpty` → `EmptyView`），不编假封面。
/// - 形态与手感：不照搬壳版圆柱环的惯性 / 弹簧（`ring.js` 的
///   SPRING 118 / TAU 1.08s / HOLD_MS 那套是全屏覆盖层环的物理，原生
///   首页环是页内一块，任务书定死跟播放页 3D 封面流同一套）——变换表、
///   阈值、死区、手势语义全部照抄 `CoverFlowView.swift`：
///   中间正对最大、两侧 rotateY ±40°/±50°、只露一部分、下面有倒影
///   （`CoverReflectionView`）；左滑上一首、右滑下一首（与 Hero 大卡
///   方向一致）、阈值 56px、8px 死区；点两侧封面切歌、点当前封面播放/暂停。
///
/// 与播放页唯一的手势差别：播放页的环用 `.gesture`，首页的环必须用
/// `.simultaneousGesture`——环住在纵向 `ScrollView` 里，`.gesture` 会
/// 抢掉落在环上的触摸、竖向滚不动；`simultaneousGesture` 让竖滑继续
/// 交给 ScrollView（Hero 大卡同款写法，见 `HeroCardView`），环只在
/// 横向占优（`|dx| > |dy|`）且 `|dx| > 56` 时切歌。环是独立区块，
/// 手势只在环自己的矩形内生效，不碰 Hero 的单击 / 双击 / 滑动 / 锁按钮。
///
/// 尺寸分档（r20：一档一套固定尺寸，不加任何 MagnificationGesture）：
/// 单张边长与轨道高直接复用 `PlayerTokens.coverItem / coverTrackHeight`，
/// 侧张偏移沿用 `CoverFlowView` 的等比式（边长 × 128/188、× 224/188）：
/// - compact（宽 ≤ 380）：边长 168，轨道高 232，侧张偏移 ±114 / ±200
/// - standard（宽 381–414）：边长 188，轨道高 254，侧张偏移 ±128 / ±224
/// - large（宽 ≥ 415）：边长 208，轨道高 280，侧张偏移 ±142 / ±248
/// 7 个平台同一套环，不分平台分支。
struct HomeCoverRingView: View {
    @EnvironmentObject private var playback: PlaybackStore

    /// 每日推荐曲目（调用方传 `viewModel.daily.map { $0.track }`）：
    /// 队列为空时环的唯一内容来源（壳版默认来源 daily，见文件头）。
    var dailyTracks: [Track] = []
    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard

    /// SwiftUI 透视系数（近似 CSS perspective: 1100px，与 CoverFlowView 同值）。
    private static let perspective3D: CGFloat = 0.5
    /// 滑动切歌阈值（壳版 bindCoverFlow：56px，与 CoverFlowView 同值）。
    private static let swipeThreshold: CGFloat = 56

    /// 每日模式下的环中心（队列模式不用它，中心就是 `currentIndex`）。
    /// 每日列表换了（切平台 / 重新拉取）就回 0，见下方 `onChange`。
    @State private var dailyCenter: Int = 0

    private var itemSize: CGFloat {
        PlayerTokens.coverItem(tier)
    }

    private var trackHeight: CGFloat {
        PlayerTokens.coverTrackHeight(tier)
    }

    /// 队列优先、每日兜底（见文件头「内容」一段）。
    private var useQueue: Bool {
        !playback.queue.isEmpty
    }

    private var tracks: [Track] {
        useQueue ? playback.queue.map { $0.track } : dailyTracks
    }

    /// 环中心下标：队列模式 = 当前播放下标；每日模式 = 本地 dailyCenter。
    private var centerIndex: Int {
        guard !tracks.isEmpty else { return 0 }
        if useQueue {
            return min(max(playback.currentIndex, 0), tracks.count - 1)
        }
        return min(max(dailyCenter, 0), tracks.count - 1)
    }

    /// 显示的 5 个位置：相对中心下标的偏移 -2…+2（队首/队尾处自然变少，不补假数据）。
    private var visibleOffsets: [Int] {
        guard !tracks.isEmpty else { return [] }
        return (-2...2).filter { tracks.indices.contains(centerIndex + $0) }
    }

    var body: some View {
        // 无曲目时不显示环、不编假封面（EmptyView 不占高度）。
        if tracks.isEmpty {
            EmptyView()
        } else {
            ZStack(alignment: .top) {
                ForEach(visibleOffsets, id: \.self) { offset in
                    coverItem(offset: offset)
                        .zIndex(zIndex(for: offset))
                }
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            // 见文件头：首页环在 ScrollView 里，必须 simultaneousGesture，
            // 否则竖向滚动会被环的拖动手势抢掉（Hero 大卡同款理由）。
            .simultaneousGesture(swipeGesture)
            .onChange(of: dailyTracks.map(\.id)) { _ in
                // 每日列表变了（切平台 / 重拉）：中心回第一首。
                dailyCenter = 0
            }
            .accessibilityLabel("封面环")
        }
    }

    // MARK: - 单张封面（结构与 CoverFlowView.coverItem 同款）

    @ViewBuilder
    private func coverItem(offset: Int) -> some View {
        let index = centerIndex + offset
        let track = tracks.indices.contains(index) ? tracks[index] : nil
        let metrics = metrics(for: offset)

        VStack(spacing: 8) {
            CoverImageView(url: track?.coverURL, placeholderIconSize: 64)
                .frame(width: itemSize, height: itemSize)
                .clipShape(RoundedRectangle(cornerRadius: PlayerTokens.radiusMd))
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 18)
                .overlay(
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
                tapCenter()
            } else if tracks.indices.contains(index) {
                select(index: index)
            }
        }
        .animation(.easeOut(duration: 0.38), value: centerIndex)
        .accessibilityLabel(tapLabel(for: offset, track: track))
    }

    // MARK: - 变换表（照抄 CoverFlowView.metrics，数值见文件头分档表）

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
        // minimumDistance 8：8px 内死区，点按不被拖动抢走（壳版同款死区，
        // 桌面环 DRAG_THRESHOLD 8、手机环 RING_THRESHOLD 5，取播放页的 8）。
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // 横向占优才算切歌：竖滑 / 斜滑交给 ScrollView（首页独有，
                // 播放页没有 ScrollView 冲突所以 CoverFlowView 不判 dy）。
                guard abs(dx) > Self.swipeThreshold, abs(dx) > abs(dy),
                      tracks.count >= 2 else { return }
                if dx < 0 {
                    // 左滑上一首（与 Hero 大卡、播放页方向一致）。
                    selectPrev()
                } else {
                    // 右滑下一首。
                    selectNext()
                }
            }
    }

    /// 左滑上一首：队列模式照抄 CoverFlowView——直接按队列下标
    /// （不走 `previous()` 的“进度 > 3 秒先回开头”分支），队首回绕到队尾；
    /// 每日模式在每日列表内回绕（壳版环是圆环，本来就转得回来）。
    private func selectPrev() {
        if useQueue {
            let prev = (centerIndex - 1 + tracks.count) % tracks.count
            select(index: prev)
        } else {
            let prev = (centerIndex - 1 + tracks.count) % tracks.count
            playback.setQueue(tracks, startAt: prev)
        }
    }

    /// 右滑下一首：队列模式走 `next()`（顺序到底停住、循环回首，和按钮一致，
    /// 与 CoverFlowView 同款）；每日模式在每日列表内回绕并整份进队列起播。
    private func selectNext() {
        if useQueue {
            playback.next()
        } else {
            let next = (centerIndex + 1) % tracks.count
            playback.setQueue(tracks, startAt: next)
        }
    }

    /// 点两侧封面切歌：队列模式 `store.play`（已在队列里只改下标，不重建队列，
    /// 与 CoverFlowView.select 同款）；每日模式整份每日进队列、从点中的起播
    /// （壳版 `playQueue(items, i, true)` 同款）。
    private func select(index: Int) {
        guard tracks.indices.contains(index) else { return }
        if useQueue {
            playback.play(tracks[index])
        } else {
            playback.setQueue(tracks, startAt: index)
        }
    }

    /// 点当前封面：队列模式 = 播放/暂停（`togglePlay`，与 CoverFlowView 同款）；
    /// 每日模式队列还是空的，`togglePlay` 会因无 currentTrack 而空转，
    /// 所以直接整份进队列起播（和点两侧封面同一条路）。
    private func tapCenter() {
        if useQueue {
            playback.togglePlay()
        } else {
            playback.setQueue(tracks, startAt: centerIndex)
        }
    }

    private func tapLabel(for offset: Int, track: Track?) -> String {
        guard let track = track else { return "封面" }
        if offset == 0 {
            return useQueue
                ? (playback.isPlaying ? "暂停：\(track.title)" : "播放：\(track.title)")
                : "播放：\(track.title)"
        }
        return "播放：\(track.title)"
    }
}
