import SwiftUI

/// 歌词区：3 行预览 + 完整歌词面板。
///
/// 规则（照抄壳版 `player.js` / `app.css` 的 `.ly` / `.ly__c` / `.ly__tr`）：
/// - 无歌词时显示「这首歌没有歌词」，绝不用 ♪ 作假。
/// - 未唱行 14px、0.55 透明度；当前行 20px、500 字重、accent 色。
/// - 逐字歌词（YRC）：唱到的字变 accent + 600 字重，未唱到的字保持暗色。
/// - 翻译行 12px 灰色，另起一行。
/// - 点一行歌词跳到该句：调 `store.seek(to:)`，时间是该行 `startMs` 换算成的秒
///   （`seek(to:)` 的入参是秒，见 PlaybackStore）。
/// - 完整面板自动跟随当前行（`currentLyricIndex` 变化时滚动到该行居中）。
struct LyricsPreviewView: View {
    @EnvironmentObject private var store: PlaybackStore

    var body: some View {
        if store.lyrics.isEmpty {
            Text("这首歌没有歌词")
                .font(.system(size: PlayerTokens.textMd))
                .foregroundStyle(PlayerTokens.playerDim)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, PlayerTokens.sp2)
        } else {
            VStack(spacing: 6) {
                previewRow(line: previousLine, isCurrent: false)
                previewRow(line: currentLine, isCurrent: true)
                previewRow(line: nextLine, isCurrent: false)
            }
        }
    }

    private var currentIndex: Int {
        // 还没开唱（-1）时预览从第一行起。
        store.currentLyricIndex >= 0 ? store.currentLyricIndex : 0
    }

    private var previousLine: LyricLine? {
        guard currentIndex > 0 else { return nil }
        return store.lyrics[currentIndex - 1]
    }

    private var currentLine: LyricLine? {
        guard store.lyrics.indices.contains(currentIndex) else { return nil }
        return store.lyrics[currentIndex]
    }

    private var nextLine: LyricLine? {
        guard store.lyrics.indices.contains(currentIndex + 1) else { return nil }
        return store.lyrics[currentIndex + 1]
    }

    @ViewBuilder
    private func previewRow(line: LyricLine?, isCurrent: Bool) -> some View {
        if let line {
            Text(line.text)
                .font(.system(
                    size: isCurrent ? 16 : PlayerTokens.textMd,
                    weight: isCurrent ? .semibold : .regular
                ))
                .foregroundStyle(isCurrent ? PlayerTokens.accent : PlayerTokens.playerDim)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // 上/下一行不存在时留空行，保持三行结构不跳动。
            Text(" ")
                .font(.system(size: PlayerTokens.textMd))
                .frame(maxWidth: .infinity)
        }
    }
}

/// 完整歌词面板：可滚动、自动跟随当前行、点行跳转。
struct FullLyricsView: View {
    @EnvironmentObject private var store: PlaybackStore

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
                            LyricRowView(line: line, isCurrent: index == store.currentLyricIndex)
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
                .font(.system(size: 20))
        } else if isCurrent {
            Text(line.text)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(PlayerTokens.accent)
        } else {
            Text(line.text)
                .font(.system(size: PlayerTokens.textMd))
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
