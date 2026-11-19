import SwiftUI

/// 歌词区（r20 播放页改版，按 01:14 播放页截图）。
///
/// 位置：封面流下方、歌名上方（放进页面由 PlayerView 负责：`lyricsZone(tier:width:)`
/// 里 `LyricsZoneView(tier:isExpanded:)`，展开态经 @Binding 接回
/// PlayerView、展开时封面流收小；不传绑定时用内部 state，无参调用仍能用）。
/// 父容器已保证最小高 = `lyricsZoneHeight(tier)`，剩余空间全归歌词区，所以本组件
/// 不再定死高度，只按实得高度底对齐内容；分档只定字号与最小高。
///
/// 折叠态（默认）：
/// - 多行歌词，当前行贴底、最大最清晰；往上的行按距离逐行变淡（透明度递减）
///   + 变模糊（.blur 递增），顶部再罩一层渐隐遮罩；随播放向上滚动
///   （`currentLyricIndex` 变化时 `ScrollViewReader.scrollTo(anchor: .bottom)`，
///   当前行始终贴底；还没开唱时从第一行起）。
/// - 逐字歌词（YRC）：当前行唱到的字 accent + 600 字重，未唱到的字暗色
///   （与 LyricRowView 的 wordByWordText 同做法）。
/// - 点一行跳到该句（`store.seek(to:)`，`startMs` → 秒）；点歌词区其他
///   位置（或右上角「展开」）展开完整歌词。
/// - 翻译行：12px 灰色，另起一行，跟在对应行下方，与正文共用同一透明度/模糊。
/// - 左上角小字「逐字」标记：仅有逐字数据时出现（顶栏徽章已撤）。
///
/// 展开态：复用 `FullLyricsView`（可滚动、自动跟随当前行、点行跳转），
/// 再点「收起」回来；当前行来自 store，展开/收起不丢当前行。
///
/// 无歌词：显示「这首歌没有歌词」，不编假数据，不用 ♪；同时收起展开态。
///
/// 分档：高度 / 字号全部走 PlayerTokens 的 tier API（工人 C 实现），本文件不写死
/// 任何型号的绝对数值；tier 由调用方注入，或组件自己按屏幕尺寸 + 顶栏安全区现算
/// （PlayerView 调的是 `LyricsZoneView(isExpanded:)`，tier 不传、走自算一路；
/// 自算用的屏幕宽与 PlayerView 的 GeometryReader 宽一致，分档结果相同）。
/// 展开态完整面板字号同样分档（r20 集成：当前行 lyricsCurrentSize，
/// 其他行 lyricsOtherSize，不再是固定 20/14）。
///
/// 禁缩放：没有任何 MagnificationGesture / 捏合手势。
struct LyricsZoneView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 展开态（r20 集成接线）：调用方传 @Binding 时由调用方持有
    /// （PlayerView 用它在展开时收小封面流）；不传时用内部 @State。
    private var externalExpanded: Binding<Bool>?
    @State private var internalExpanded = false

    /// 展开态读写：有外部绑定走外部，否则走内部 state。
    private var isExpanded: Bool {
        get { externalExpanded?.wrappedValue ?? internalExpanded }
        nonmutating set {
            if let externalExpanded {
                externalExpanded.wrappedValue = newValue
            } else {
                internalExpanded = newValue
            }
        }
    }

    /// 调用方注入的分档（PlayerView 的 GeometryReader 已有全屏尺寸时可传进来）；
    /// 不传时组件按屏幕尺寸 + 顶栏安全区自己取档。两种写法结果一致，不打架。
    var injectedTier: PlayerTokens.PlayerSizeTier?

    init(tier: PlayerTokens.PlayerSizeTier? = nil, isExpanded: Binding<Bool>? = nil) {
        self.injectedTier = tier
        self.externalExpanded = isExpanded
    }

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

    private var hasWordLyrics: Bool {
        store.lyrics.contains { !$0.words.isEmpty }
    }

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
        .onChange(of: store.lyrics.isEmpty) { empty in
            // 无歌词时清状态：收起展开态。
            if empty { isExpanded = false }
        }
    }

    @ViewBuilder
    private func content(zoneWidth: CGFloat, zoneHeight: CGFloat) -> some View {
        if store.lyrics.isEmpty {
            emptyState
        } else if isExpanded {
            expandedState(zoneWidth: zoneWidth)
        } else {
            collapsedState(zoneWidth: zoneWidth, zoneHeight: zoneHeight)
        }
    }

    // MARK: - 无歌词

    private var emptyState: some View {
        Text("这首歌没有歌词")
            .font(.system(size: PlayerTokens.textMd))
            .foregroundStyle(PlayerTokens.playerDim)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - 折叠态：底对齐多行 + 渐隐 + 平滑滚动

    private func collapsedState(zoneWidth: CGFloat, zoneHeight: CGFloat) -> some View {
        ZStack(alignment: .top) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // 不用 LazyVStack：要 scrollTo 落点精确（行高含翻译行、
                    // 各行不等高），折叠态只渲染到当前行，行数有限，全量布局更稳。
                    VStack(spacing: 2) {
                        // 顶部留白：给左上角「逐字」标记让位，不压住最上一行。
                        Color.clear.frame(height: 20)
                        ForEach(visibleIndices, id: \.self) { index in
                            let line = store.lyrics[index]
                            LyricsZoneRowView(
                                line: line,
                                distance: effectiveCurrent - index,
                                currentSize: currentSize,
                                otherSize: otherSize
                            )
                            .id(index)
                            // 行点按优先于歌词区点按：高优先级手势，点行只跳转、不展开。
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
                // 禁手动滚动：自动跟随独占滚动，手指只点行跳转 / 点空白处展开。
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
            collapsedHeader
        }
        .contentShape(Rectangle())
        // 点歌词区空白处展开完整歌词（点行是跳转，见行上的高优先级手势）。
        .onTapGesture { isExpanded = true }
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

    /// 折叠态顶栏（悬浮，不占布局高度）：左「逐字」小标记，右「展开」。
    private var collapsedHeader: some View {
        HStack(alignment: .top, spacing: 0) {
            if hasWordLyrics {
                Text("逐字")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
                    .accessibilityLabel("逐字歌词")
            }
            Spacer()
            HStack(spacing: 2) {
                Text("展开")
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.55))
            .accessibilityLabel("展开完整歌词")
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    // MARK: - 展开态：复用完整歌词面板

    private func expandedState(zoneWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("完整歌词")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                if hasWordLyrics {
                    Text("逐字")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        )
                        .accessibilityLabel("逐字歌词")
                }
                Spacer()
                HStack(spacing: 2) {
                    Text("收起")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded = false }
            .accessibilityLabel("收起完整歌词")
            // FullLyricsView 自己可滚动、自动跟随当前行、点行跳转；
            // 当前行来自 store，展开/收起不丢当前行。字号按 tier 分档。
            // r21b：显式给区宽，与折叠态同理——完整歌词的长行也不得报出
            // 比区宽更大的理想宽。
            FullLyricsView(tier: tier)
                .frame(width: zoneWidth)
        }
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

/// 歌词区一行（折叠态用）：当前行大 + 清晰，往上按距离逐行变淡变模糊。
///
/// - 逐字：仅当前行 + 有 words 时，唱到的字 accent + 600 字重
///   （与 LyricRowView 的 wordByWordText 同做法）；未唱到的字暗色。
/// - 翻译：12px 灰色另起一行；整行共用同一透明度 / 模糊，渐隐不断层。
/// - 单行省略（lineLimit 1）：行高均匀，区高账可算，不挤占上下区块。
private struct LyricsZoneRowView: View {
    @EnvironmentObject private var store: PlaybackStore

    let line: LyricLine
    /// 与当前行的距离：0 = 当前行，1 = 上一行，依此类推。
    let distance: Int
    let currentSize: CGFloat
    let otherSize: CGFloat

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
                    .foregroundStyle(PlayerTokens.playerTranslation)
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
                .foregroundStyle(PlayerTokens.accent)
                .lineLimit(1)
        } else {
            Text(line.text)
                .font(.system(size: otherSize))
                .foregroundStyle(PlayerTokens.playerDim)
                .lineLimit(1)
        }
    }

    private var wordByWordText: Text {
        line.words.reduce(Text("")) { partial, word in
            let sung = word.startMs <= nowMs
            let piece = Text(word.text)
                .foregroundColor(sung ? PlayerTokens.accent : PlayerTokens.playerDim)
                .fontWeight(sung ? .semibold : .regular)
            return partial + piece
        }
    }
}

/// 完整歌词面板：可滚动、自动跟随当前行、点行跳转。
/// 字号按 tier 分档（r20 集成）：当前行 lyricsCurrentSize（22/24/26），
/// 其他行 lyricsOtherSize（15/16/17）；翻译行仍是 textXs 12。
struct FullLyricsView: View {
    @EnvironmentObject private var store: PlaybackStore

    /// 分档（调用方注入；默认 standard，只在无参调用时用）。
    var tier: PlayerTokens.PlayerSizeTier = .standard

    private var currentSize: CGFloat { PlayerTokens.lyricsCurrentSize(tier) }
    private var otherSize: CGFloat { PlayerTokens.lyricsOtherSize(tier) }

    var body: some View {
        if store.lyrics.isEmpty {
            VStack {
                Spacer()
                Text("这首歌没有歌词")
                    .font(.system(size: PlayerTokens.textMd))
                    .foregroundStyle(PlayerTokens.playerDim)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        // 上下各留一行的呼吸空间（壳版 .lyrics 上下 padding 各 1 行）。
                        Color.clear.frame(height: 24)
                        // 用下标作 id：副歌重复行会出现 startMs + 文本都相同的行，
                        // LyricLine.id 会撞车，ForEach 必须用唯一 id。
                        ForEach(Array(store.lyrics.enumerated()), id: \.offset) { index, line in
                            LyricRowView(line: line, isCurrent: index == store.currentLyricIndex,
                                         currentSize: currentSize, otherSize: otherSize)
                                .id(index)
                                .onTapGesture { seek(to: line) }
                        }
                        Color.clear.frame(height: 24)
                    }
                }
                .onAppear { scrollToCurrent(proxy: proxy, animated: false) }
                .onChange(of: store.currentLyricIndex) { _ in
                    scrollToCurrent(proxy: proxy, animated: true)
                }
            }
        }
    }

    private func scrollToCurrent(proxy: ScrollViewProxy, animated: Bool) {
        guard store.currentLyricIndex >= 0,
              store.lyrics.indices.contains(store.currentLyricIndex) else { return }
        let id = store.currentLyricIndex
        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func seek(to line: LyricLine) {
        // seek(to:) 入参是秒；行时间是毫秒。
        store.seek(to: TimeInterval(line.startMs) / 1000)
    }
}

/// 一行歌词（完整面板用）。
private struct LyricRowView: View {
    @EnvironmentObject private var store: PlaybackStore

    let line: LyricLine
    let isCurrent: Bool
    /// 分档字号（调用方 FullLyricsView 按 tier 传进来）。
    let currentSize: CGFloat
    let otherSize: CGFloat

    /// 当前播放进度（毫秒），逐字高亮用。
    private var nowMs: Int { Int(store.progress * 1000) }

    var body: some View {
        VStack(spacing: 2) {
            lyricText
            if !line.translation.isEmpty {
                Text(line.translation)
                    .font(.system(size: PlayerTokens.textXs))
                    .foregroundStyle(PlayerTokens.playerTranslation)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var lyricText: some View {
        if isCurrent, !line.words.isEmpty {
            // 当前行 + 有逐字数据：逐字上色（唱到的字 accent + 600 字重）。
            // 这里只定字号，字重由每个字的 sung 状态自己定（见 wordByWordText）。
            wordByWordText
                .font(.system(size: currentSize))
        } else if isCurrent {
            Text(line.text)
                .font(.system(size: currentSize, weight: .medium))
                .foregroundStyle(PlayerTokens.accent)
        } else {
            Text(line.text)
                .font(.system(size: otherSize))
                .foregroundStyle(PlayerTokens.playerDim)
                .opacity(0.55)
        }
    }

    private var wordByWordText: Text {
        line.words.reduce(Text("")) { partial, word in
            let sung = word.startMs <= nowMs
            let piece = Text(word.text)
                .foregroundColor(sung ? PlayerTokens.accent : PlayerTokens.playerDim)
                .fontWeight(sung ? .semibold : .regular)
            return partial + piece
        }
    }
}
