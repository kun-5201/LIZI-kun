import SwiftUI

/// 歌词区（r20 播放页改版，按 01:14 播放页截图；r27 删歌词展开功能）。
///
/// 位置：封面流下方、歌名上方（放进页面由 PlayerView 负责：`lyricsZone(tier:width:)`
/// 里 `LyricsZoneView(tier:)`）。
/// 父容器已保证最小高 = `lyricsZoneHeight(tier)`，剩余空间全归歌词区，所以本组件
/// 不再定死高度，只按实得高度底对齐内容；分档只定字号与最小高。
///
/// r27：歌词展开功能已整个删除——没有「展开」入口、没有展开态面板、没有
/// 点空白处展开的手势、展开时收小封面流的联动也一并删了（见 PlayerView）。
/// 歌词区只剩一种形态（下面「歌词显示」），不要再往本文件加回展开态。
///
/// 歌词显示：
/// - 多行歌词，当前行贴底、最大最清晰；往上的行按距离逐行变淡（透明度递减）
///   + 变模糊（.blur 递增），顶部再罩一层渐隐遮罩；随播放向上滚动
///   （`currentLyricIndex` 变化时 `ScrollViewReader.scrollTo(anchor: .bottom)`，
///   当前行始终贴底；还没开唱时从第一行起）。
/// - 逐字歌词（YRC）：当前行唱到的字 accent + 600 字重，未唱到的字暗色
///   （逐字上色见 LyricsZoneRowView.wordByWordText）。
/// - 点一行跳到该句（`store.seek(to:)`，`startMs` → 秒）；点歌词区其他
///   位置什么都不做（r27：点空白处不再展开）。
/// - 翻译行：12px 灰色，另起一行，跟在对应行下方，与正文共用同一透明度/模糊。
///
/// 无歌词：显示「这首歌没有歌词」，不编假数据，不用 ♪。
///
/// 分档：高度 / 字号全部走 PlayerTokens 的 tier API（工人 C 实现），本文件不写死
/// 任何型号的绝对数值；tier 由调用方注入，或组件自己按屏幕尺寸 + 顶栏安全区现算
/// （PlayerView 调的是 `LyricsZoneView(tier:)`，tier 不传、走自算一路；
/// 自算用的屏幕宽与 PlayerView 的 GeometryReader 宽一致，分档结果相同）。
///
/// 禁缩放：没有任何 MagnificationGesture / 捏合手势。
struct LyricsZoneView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 调用方注入的分档（PlayerView 的 GeometryReader 已有全屏尺寸时可传进来）；
    /// 不传时组件按屏幕尺寸 + 顶栏安全区自己取档。两种写法结果一致，不打架。
    var injectedTier: PlayerTokens.PlayerSizeTier?
    /// r39-2：专辑 tone（调用方 PlayerView 传 playerTone；默认 fallback）。
    /// 只改歌词颜色，不动排版/滚动/手势。
    var albumTone: AlbumTone = .fallback

    init(tier: PlayerTokens.PlayerSizeTier? = nil, albumTone: AlbumTone = .fallback) {
        self.injectedTier = tier
        self.albumTone = albumTone
    }

    /// r39-2：专辑强调色 / 文字色 / 次要文字色（与 PlayerView 同一套取法：
    /// 强调色深场取 c、浅场取 a；文字走 AlbumTone.text / secondaryText）。
    private var albumAccent: Color { albumTone.isDark ? albumTone.c : albumTone.a }
    private var albumText: Color { albumTone.text }
    private var albumSecondaryText: Color { albumTone.secondaryText }

    // MARK: - 分档（只按宽度分，见 PlayerTokens.sizeTier 注释）

    private var tier: PlayerTokens.PlayerSizeTier {
        if let injectedTier { return injectedTier }
        return PlayerTokens.sizeTier(for: UIScreen.main.bounds.size,
                                     topInset: Self.keyWindowTopInset)
    }

    /// 顶栏安全区真实值（无窗口时按刘海机型 47 兜底；只传进 sizeTier，
    /// 不参与分档，见 PlayerTokens 注释）。
    private static var keyWindowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 47
    }

    private var currentSize: CGFloat { PlayerTokens.lyricsCurrentSize(tier) }
    private var otherSize: CGFloat { PlayerTokens.lyricsOtherSize(tier) }

    /// 有效当前行：还没开唱（-1）时从第一行起；越界时夹到末行。
    private var effectiveCurrent: Int {
        guard !store.lyrics.isEmpty else { return 0 }
        if store.currentLyricIndex < 0 { return 0 }
        return min(store.currentLyricIndex, store.lyrics.count - 1)
    }

    /// 折叠态渲染的行：从第一行到当前行（只往上、不往下看，当前行贴底）。
    private var visibleIndices: [Int] {
        guard !store.lyrics.isEmpty else { return [] }
        return Array(0...effectiveCurrent)
    }

    var body: some View {
        // 根 GeometryReader 只量父容器实际给的高度（弹性段实得高），
        // 不拿它做分档：分档用屏幕宽（见 tier），区宽比屏宽窄 32，
        // 拿区宽去分档会在 390/430 屏上错档。
        // r21b：内容同时拿区宽锚定 ScrollView 内容宽（见 content 注释）——
        // 折叠态 ScrollView 里的单行歌词行不得报出比区宽更大的理想宽，
        // 否则会一路顶大父级 VStack（r20 竖屏右移的嫌疑链）。
        GeometryReader { geo in
            content(zoneWidth: geo.size.width, zoneHeight: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(zoneWidth: CGFloat, zoneHeight: CGFloat) -> some View {
        if store.lyrics.isEmpty {
            emptyState
        } else {
            lyricsState(zoneWidth: zoneWidth, zoneHeight: zoneHeight)
        }
    }

    // MARK: - 无歌词

    private var emptyState: some View {
        Text("这首歌没有歌词")
            .font(.system(size: PlayerTokens.textMd))
            .foregroundStyle(albumSecondaryText) // r39-2：无歌词提示走专辑次要文字色
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - 歌词显示：底对齐多行 + 渐隐 + 平滑滚动

    private func lyricsState(zoneWidth: CGFloat, zoneHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // 不用 LazyVStack：要 scrollTo 落点精确（行高含翻译行、
                    // 各行不等高），折叠态只渲染到当前行，行数有限，全量布局更稳。
                    VStack(spacing: 2) {
                        ForEach(visibleIndices, id: \.self) { index in
                            let line = store.lyrics[index]
                            LyricsZoneRowView(
                                line: line,
                                distance: effectiveCurrent - index,
                                currentSize: currentSize,
                                otherSize: otherSize,
                                albumTone: albumTone // r39-2：行接专辑 tone
                            )
                            .id(index)
                            // 行点按只跳转（点行是跳转，见行上的高优先级手势）。
                            .highPriorityGesture(
                                TapGesture().onEnded { seek(to: line) }
                            )
                        }
                    }
                    // 内容不足一屏时也撑满区高、底对齐：当前行永远贴底、完整可见。
                    // r21b：显式给区宽——ScrollView 内容的布局宽由它定，不由最长
                    // 单行歌词的理想宽定（否则理想宽会沿 GeometryReader → ZStack
                    // → VStack 一路顶上去，见 PlayerView 文件底「r21b 根因」）。
                    // SwiftUI 没有 frame(width:minHeight:alignment:) 这一重载，
                    // 用 minWidth/maxWidth 夹住宽度，语义与固定宽相同。
                    .frame(minWidth: zoneWidth, maxWidth: zoneWidth, minHeight: zoneHeight, alignment: .bottom)
                }
                // 禁手动滚动：自动跟随独占滚动，手指只点行跳转；点歌词区
                // 空白处什么都不做（r27：点空白处展开已删）。
                .scrollDisabled(true)
                // 顶部渐隐遮罩：最上一行淡出，不与封面流生硬交界。
                .mask(topFadeMask)
                .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
                .onChange(of: store.currentLyricIndex) { _ in
                    scrollToCurrent(proxy: proxy, animated: true)
                }
                .onChange(of: store.lyrics) { _ in
                    scrollToCurrent(proxy: proxy, animated: false)
                }
            }
        }
        // r27：点歌词区空白处不再展开（展开功能已删），这里不挂任何点按手势；
        // 点行跳转走行上的高优先级手势。
    }

    /// 顶部渐隐：0 → 30% 从透明到不透明，下方全不透明。
    private var topFadeMask: some View {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.3),
                .init(color: .black, location: 1),
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - 滚动锚点 / 跳转

    /// 滚到当前行，锚点 .bottom：当前行底边贴住歌词区底边。
    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard !store.lyrics.isEmpty,
              store.lyrics.indices.contains(effectiveCurrent) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(effectiveCurrent, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(effectiveCurrent, anchor: .bottom)
        }
    }

    private func seek(to line: LyricLine) {
        // seek(to:) 入参是秒；行时间是毫秒。
        store.seek(to: TimeInterval(line.startMs) / 1000)
    }
}

/// 歌词区一行：当前行大 + 清晰，往上按距离逐行变淡变模糊。
///
/// - 逐字：仅当前行 + 有 words 时，唱到的字 accent + 600 字重
///   （逐字上色见本 struct 的 wordByWordText）；未唱到的字暗色。
/// - 翻译：12px 灰色另起一行；整行共用同一透明度 / 模糊，渐隐不断层。
/// - 单行省略（lineLimit 1）：行高均匀，区高账可算，不挤占上下区块。
private struct LyricsZoneRowView: View {
    @EnvironmentObject private var store: PlaybackStore

    let line: LyricLine
    /// 与当前行的距离：0 = 当前行，1 = 上一行，依此类推。
    let distance: Int
    let currentSize: CGFloat
    let otherSize: CGFloat
    /// r39-2：专辑 tone（调用方 LyricsZoneView 传下来）。
    let albumTone: AlbumTone

    /// r39-2：专辑强调色 / 次要文字色（与 LyricsZoneView 同一套取法）。
    private var albumAccent: Color { albumTone.isDark ? albumTone.c : albumTone.a }
    private var albumSecondaryText: Color { albumTone.secondaryText }

    private var isCurrent: Bool { distance == 0 }

    /// 当前播放进度（毫秒），逐字高亮用。
    private var nowMs: Int { Int(store.progress * 1000) }

    /// 透明度：当前行 1；上一行 0.55，之后每行 ×0.65
    /// （0.36 / 0.23 / 0.15 / 0.10 …），配顶部渐隐遮罩淡出。
    private var rowOpacity: Double {
        guard distance > 0 else { return 1 }
        return 0.55 * pow(0.65, Double(distance - 1))
    }

    /// 模糊：当前行 0；上一行 0.6，之后每行 +1.2
    /// （1.8 / 3.0 / 4.2 / 5.4 …），越往上越糊。
    private var rowBlur: CGFloat {
        guard distance > 0 else { return 0 }
        return 0.6 + 1.2 * CGFloat(distance - 1)
    }

    var body: some View {
        VStack(spacing: 2) {
            lyricText
            if !line.translation.isEmpty {
                Text(line.translation)
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(albumSecondaryText) // r39-2：翻译行走专辑次要文字色
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
        .opacity(rowOpacity)
        .blur(radius: rowBlur)
        .accessibilityLabel("歌词：\(line.text)，点按跳转到该句")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var lyricText: some View {
        if isCurrent, !line.words.isEmpty {
            // 当前行 + 有逐字数据：逐字上色（唱到的字 accent + 600 字重）。
            wordByWordText
                .font(.system(size: currentSize))
                .lineLimit(1)
        } else if isCurrent {
            Text(line.text)
                .font(.system(size: currentSize, weight: .semibold))
                .foregroundStyle(albumAccent) // r39-2：竖屏当前行走专辑强调色
                .lineLimit(1)
        } else {
            Text(line.text)
                .font(.system(size: otherSize))
                .foregroundStyle(albumSecondaryText) // r39-2：非当前行走专辑次要文字色
                .lineLimit(1)
        }
    }

    private var wordByWordText: Text {
        line.words.reduce(Text("")) { partial, word in
            let sung = word.startMs <= nowMs
            let piece = Text(word.text)
                .foregroundColor(sung ? albumAccent : albumSecondaryText) // r39-2：逐字唱到走专辑强调色，未唱到走专辑次要文字色
                .fontWeight(sung ? .semibold : .regular)
            return partial + piece
        }
    }
}
