import SwiftUI

/// 搜索结果曲目行（照抄壳版 .track 的结构与尺寸，iOS 原生实现）。
///
/// 每行 = 封面 + 歌名 + 歌手·专辑 + VIP 小签 + 时长（等宽字体）。
/// - 歌名：31pt / 窄屏 20pt、600 字重、单行省略；正在播的行歌名变 accent 色。
/// - 歌手·专辑：14pt（窄屏 13pt）、墨色弱化、单行省略。
/// - 封面：窄屏 56pt，其余 76pt；无封面先占位（白色底 + 音符，不用金色）。
/// - 时长：等宽字体；时长未知（durationMs <= 0）时不显示，不编假时长。
/// - 长按菜单（r31）：`.playNextMenu(track:)`，菜单里「下一首播放」，
///   点一下插到当前曲目之后、当前播完就播它。六处共用本行（搜索结果、
///   歌单详情、歌手页热门/全部、专辑页、榜单详情），一处挂上六处都有入口。
///   点行本身仍是点播（setQueue 从该位置起播），长按才出菜单，互不抢。
///
/// 封面取色 wash 渐变（壳版 .track::after 的模糊渐变）P1 没做：取色链路
/// 在播放页/封面模块，不在本文件里另起一套；如需补，由集成工人统一接。
struct TrackRowView: View {
    let track: Track
    /// 是否正在播（歌名变 accent 色）。
    let isCurrent: Bool
    /// 窄屏（compact width）：封面 56、歌名 20；否则封面 76、歌名 31。
    let isCompact: Bool
    let onTap: () -> Void

    private var coverSize: CGFloat { isCompact ? 56 : 76 }
    private var titleSize: CGFloat { isCompact ? SearchDesignTokens.size20 : SearchDesignTokens.size31 }
    private var subSize: CGFloat { isCompact ? SearchDesignTokens.size13 : SearchDesignTokens.size14 }

    /// 歌手·专辑（两边非空的才拼「·」）。
    private var subtitle: String {
        [track.artist, track.album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 时长 m:ss；未知时为空字符串。
    private var durationText: String {
        guard track.durationMs > 0 else { return "" }
        let seconds = track.durationMs / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: isCompact ? 12 : 16) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(SearchDesignTokens.font(titleSize, weight: .semibold))
                        .foregroundStyle(isCurrent ? SearchDesignTokens.accent : SearchDesignTokens.ink)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(SearchDesignTokens.font(subSize))
                            .foregroundStyle(SearchDesignTokens.ink3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if track.vip {
                    vipBadge
                }
                if !durationText.isEmpty {
                    Text(durationText)
                        .font(SearchDesignTokens.monoFont(SearchDesignTokens.size14))
                        .foregroundStyle(SearchDesignTokens.ink3)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isCurrent ? SearchDesignTokens.rowHighlight : Color.clear)
        .playNextMenu(track: track)
    }

    // MARK: - 封面

    @ViewBuilder
    private var cover: some View {
        Group {
            ProxyImageView(url: track.coverURL) { placeholder }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius10))
    }

    private var placeholder: some View {
        ZStack {
            SearchDesignTokens.coverPlaceholder
            Image(systemName: "music.note")
                .font(.system(size: isCompact ? 18 : 24))
                .foregroundStyle(SearchDesignTokens.ink3)
        }
    }

    // MARK: - VIP 小签

    private var vipBadge: some View {
        Text("VIP")
            .font(SearchDesignTokens.font(SearchDesignTokens.size12, weight: .semibold))
            .foregroundStyle(SearchDesignTokens.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: SearchDesignTokens.radius10)
                    .stroke(SearchDesignTokens.accent.opacity(0.5), lineWidth: 1)
            )
    }
}

/// 「全部」源时的分组标题行（壳版 .track-group：细线 + 小字，不是卡片）。
struct SearchGroupHeaderView: View {
    let title: String
    /// 该组上游总条数（未知时为 0，只显示已加载数时传 tracks.count）。
    let count: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size12, weight: .semibold))
                    .foregroundStyle(SearchDesignTokens.ink3)
                Text("\(count)")
                    .font(SearchDesignTokens.monoFont(SearchDesignTokens.size12))
                    .foregroundStyle(SearchDesignTokens.ink3)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            Rectangle()
                .fill(SearchDesignTokens.rule)
                .frame(height: 0.5)
                .padding(.horizontal, 16)
        }
    }
}

/// 歌手 / 专辑 / 歌单名：P1 只做纯文本展示，不做按钮。
/// 歌手页 / 专辑页 / 歌单详情是 P2 的活，点按行为 P2 接；这里故意不用 Button，
/// 不做点了没反应的死按钮。桥接层目前只回 tracks，这些行现在不会出现，
/// 只是把展示形态先定死，等桥接填数据就能直接用。
struct SearchPlainRowView: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SearchDesignTokens.font(SearchDesignTokens.size16, weight: .semibold))
                    .foregroundStyle(SearchDesignTokens.ink)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                        .foregroundStyle(SearchDesignTokens.ink3)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }
}
