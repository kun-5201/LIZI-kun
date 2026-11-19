import SwiftUI

/// 播放页设计令牌。
///
/// 共享令牌（纸面 / 墨色 / accent / 字号 / 圆角）复用首页工人已建的
/// `LiziTokens`（`Views/Home/DesignTokens.swift`，同样照抄壳版
/// `public/tokens.css`），全 App 只有一个 accent，不另起第二套色板。
/// 这里只补播放页自己用的：深色页前景（壳版 `body.is-now` 的白字透明度）、
/// 封面取色缺省三色调、dock 渐变两端、播放页尺寸分档（r20：一档一套固定尺寸）。
///
/// 色值说明：tone / bar 两组是 tokens.css 里 OKLCH 值转 sRGB 的结果
/// （Xcode 没有 OKLCH 字面量；标准 oklch→linear sRGB 矩阵算出）：
/// tone-a oklch(72% 0.16 264) → #70A1FF，tone-b (76% 0.14 190) → #00CDC5，
/// tone-c (80% 0.13 340) → #F59CD8；bar-a (72% 0.14 275) → #8C9CFB，
/// bar-b (56% 0.16 275) → #5B68D0。
enum PlayerTokens {

    // MARK: - 共享令牌（复用 LiziTokens，不复制第二份）

    static let paper = LiziTokens.paper
    static let paper2 = LiziTokens.paper2
    static let ink = LiziTokens.ink
    static let ink2 = LiziTokens.ink2
    static let ink3 = LiziTokens.ink3
    /// 唯一强调色（网易云红）；只在设置页可重定义，全局不动。
    static let accent = LiziTokens.accent
    static let accentInk = LiziTokens.accentInk
    static let rule = LiziTokens.rule

    /// 封面取色缺省三色调（JS 会按封面动态覆写；原生版 P1 先用缺省值）。
    static let toneA = Color(hex: 0x70A1FF)
    static let toneB = Color(hex: 0x00CDC5)
    static let toneC = Color(hex: 0xF59CD8)

    /// dock 渐变进度条两端（app.css `.dock__paint` 的 --bar-a / --bar-b 缺省值）。
    static let barA = Color(hex: 0x8C9CFB)
    static let barB = Color(hex: 0x5B68D0)

    // MARK: - 播放页深色前景（app.css body.is-now）

    static let playerForeground = Color.white
    /// 未唱歌词 / 次要文字（oklch 100% 0 0 / 0.52）。
    static let playerDim = Color.white.opacity(0.52)
    /// 副标题（oklch 100% 0 0 / 0.72）。
    static let playerSub = Color.white.opacity(0.72)
    /// 翻译行（oklch 100% 0 0 / 0.58）。
    static let playerTranslation = Color.white.opacity(0.58)

    // MARK: - 字号（tokens.css：比率 1.25，基准 16px；与 LiziTokens.size* 同值）

    static let text2xs: CGFloat = 10
    static let textXs: CGFloat = 12
    static let textSm: CGFloat = 13
    static let textMd: CGFloat = 14
    static let textBase: CGFloat = 16
    static let textLg: CGFloat = 20
    static let textXl: CGFloat = 25
    static let text2xl: CGFloat = 31
    /// 播放页大标题（--text-3xl，39px）。
    static let text3xl: CGFloat = 39

    // MARK: - 间距（tokens.css：4pt 级数）

    static let sp1: CGFloat = 4
    static let sp2: CGFloat = 8
    static let sp3: CGFloat = 12
    static let sp4: CGFloat = 16
    static let sp5: CGFloat = 20
    static let sp6: CGFloat = 24
    static let sp7: CGFloat = 32
    static let sp8: CGFloat = 40

    // MARK: - 圆角

    static let radiusSm: CGFloat = 10
    static let radiusMd: CGFloat = 14
    static let radiusLg: CGFloat = 20
    static let radiusFull: CGFloat = 999

    // MARK: - 播放页尺寸分档（r20，用户新要求：一档一套固定尺寸）

    /// 播放页尺寸档：只按屏幕宽度分。
    /// - compact：宽 ≤ 380（SE / mini，约 375pt）
    /// - standard：381…414（6.1 寸，约 390pt）
    /// - large：宽 ≥ 415（Pro Max，约 430pt）
    /// 分档阈值只写在这里，调用方只传实测尺寸，不在各处另写阈值。
    enum PlayerSizeTier {
        case compact
        case standard
        case large
    }

    /// 按宽度分档。`topInset` 是调用方传的真实 `safeAreaInsets.top`（无刘海 /
    /// 刘海 / 灵动岛三种顶部形态都由它区分）：分档本身只看宽度，topInset
    /// 不参与分档；它留在这里是为两点——(1) 令牌层不写死任何顶部 padding
    /// 常量，顶部留白一律由调用方按传进来的 topInset 现算（topInset + 间隙）；
    /// (2) 将来刘海/灵动岛形态需要拆档时不用改调用点。
    /// 顶部形态参考：无刘海 SE topInset ≈ 20；刘海/灵动岛机型 ≈ 44…59。
    static func sizeTier(for size: CGSize, topInset: CGFloat) -> PlayerSizeTier {
        // topInset 不改变档位（见上方注释）；宽度是唯一分档依据。
        _ = topInset
        switch size.width {
        case ...380:
            return .compact
        case 381...414:
            return .standard
        default:
            return .large
        }
    }

    // MARK: - 每档尺寸（函数名是 r20 跨工人约定，一个字不许改）

    /// 总高度账（纵向一段到底，单位 pt；间隙为调用方 PlayerView 的段间距）：
    /// 顶栏(= topBarButton) + 间隙 6 + 封面流 + 间隙 8 + 歌词区 + 间隙 8
    /// + 歌名块（歌名行高 ≈ titleSize × 1.25 + 间距 2 + 副标题行高 ≈ subtitleSize × 1.3）
    /// + 间隙 10 + 控制行(= playSize) + 间隙 12 + 进度条外框 32
    /// （视觉细条 progressHeight = 4，触摸区 touchHeight = 32，计账按外框 32，
    /// r20 工人 E 集成修正：之前按 4 计少了 28）
    /// + 顶部安全区 topInset + 底部安全区（Home Indicator）。
    ///
    /// - compact（375×667 SE 最短屏，topInset 20，底部 0）：
    ///   20 + 44 + 6 + 232 + 8 + 150 + 8 + 54 + 10 + 60 + 12 + 32 + 0 = 636 ≤ 667，余 31。
    ///   状态角标行（音质/试听/演示）有内容时再 +22，658 ≤ 667 仍过。
    ///   同档 mini（375×812，topInset 50，底部 34）：636 − 20 + 50 + 34 = 700 ≤ 812。
    /// - standard（390×844，topInset 47，底部 34）：
    ///   47 + 48 + 6 + 254 + 8 + 180 + 8 + 60 + 10 + 68 + 12 + 32 + 34 = 767 ≤ 844，余 77。
    /// - large（430×932，topInset 59，底部 34）：
    ///   59 + 52 + 6 + 280 + 8 + 210 + 8 + 67 + 10 + 76 + 12 + 32 + 34 = 854 ≤ 932，余 78。
    /// 余量归调用方的弹性歌词区/段间距消化，不另加固定高度。

    /// 毛玻璃圆按钮直径（顶栏返回/搜索/设置等）。
    static func topBarButton(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 44
        case .standard: return 48
        case .large: return 52
        }
    }

    /// 单张封面边长。
    static func coverItem(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 168
        case .standard: return 188
        case .large: return 208
        }
    }

    /// 封面流轨道高（含倒影）。内部账：单张 + 间距 8 + 倒影（单张 × 0.3）：
    /// compact 168 + 8 + 50.4 = 226.4 ≤ 232；
    /// standard 188 + 8 + 56.4 = 252.4 ≤ 254；
    /// large 208 + 8 + 62.4 = 278.4 ≤ 280。
    static func coverTrackHeight(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 232
        case .standard: return 254
        case .large: return 280
        }
    }

    /// 歌词区高。
    static func lyricsZoneHeight(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 150
        case .standard: return 180
        case .large: return 210
        }
    }

    /// 当前歌词行字号。
    static func lyricsCurrentSize(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 22
        case .standard: return 24
        case .large: return 26
        }
    }

    /// 其他歌词行字号。
    static func lyricsOtherSize(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 15
        case .standard: return 16
        case .large: return 17
        }
    }

    /// 歌名字号。
    static func titleSize(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 28
        case .standard: return 32
        case .large: return 36
        }
    }

    /// 歌手·专辑字号。
    static func subtitleSize(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 13
        case .standard: return 14
        case .large: return 15
        }
    }

    /// 大播放键直径（控制行行高 = 此值）。
    static func playSize(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 60
        case .standard: return 68
        case .large: return 76
        }
    }

    /// 控制行小图标字号（上一首/下一首/队列列表）。
    static func controlIconSize(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 22
        case .standard: return 24
        case .large: return 26
        }
    }

    /// 底部细进度条高（三档同值）。
    static func progressHeight(_ tier: PlayerSizeTier) -> CGFloat {
        _ = tier
        return 4
    }

    // MARK: - 旧固定尺寸常量（r20 已删）
    //
    // coverFlowTrackHeight / coverFlowTrackHeightCompact / coverFlowItemSize /
    // coverFlowItemSizeCompact / dockHeight / transportButtonSize /
    // transportPlaySize 全部删除，不留废弃兼容：播放页布局一律走上面
    // 的 per-tier 函数。删的理由：固定值正是 r20 要换掉的东西，留着只会
    // 让新旧两套尺寸并存、迟早有人误引。

    // MARK: - 时长格式化（mm:ss，tokens.css --font-mono 的等宽数字意图）

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
