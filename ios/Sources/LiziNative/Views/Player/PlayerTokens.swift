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
    /// 顶栏（r27 起竖屏固定 49pt，实测值，见 PlayerView.topBar 注释；
    /// 本函数 topBarButton 的 44/48/52 只剩横屏胶囊在用）+ 间隙 6 + 封面流
    /// + 间隙 8 + 歌词区 + 间隙 8
    /// + 歌名块（歌名行高 ≈ titleSize × 1.25 + 间距 2 + 副标题行高 ≈ subtitleSize × 1.3）
    /// + 间隙 8 + 第二行 36（非 compact 档；compact 不渲染）
    /// + 间隙 8 + 底部三排（第 3 排 32/26 + 间隙 8/2 + 第 2 排进度条 50/46
    /// + 间隙 8/2 + 最下面一排 61/42，标准/compact；large 32/51/68；
    /// dock 上间隙 8，compact 4）
    /// + 底部安全区（Home Indicator）。
    /// r27 压缩轮：compact 封面 232 → 209、dock 132 → 118、dock 上间距
    /// 8 → 4，合计 −41；large 有角标态 title 间距 + 角标行共 −15；
    /// standard 一字不动。上一版两处总账漏计 titleBlock 下间距 10pt
    /// （无角标 10、有角标 compact/large 4），本轮已纠正（见 PlayerView
    /// 文件底 r27 段落）。
    /// r27：默认版式换 v4 dock 后纸面总账如下（02/04/06 变体仍走旧控制行，
    /// 不用这套数）。纸面口径顶边是 topInset（20/47/59），与实测顶边 39
    /// 的档位有基线差，真机以 PlayerView 文件底 r27 实账为准。
    ///
    /// - compact（375×667 SE 最短屏，topInset 20，底部 0；r27 压缩后）：
    ///   20 + 49 + 6 + 209 + 8 + 150 + 8 + 54 + 10 + 4 + 26 + 2 + 46 + 2 + 42 + 0 = 636 ≤ 667，余 31。
    ///   状态角标行净 +7（间距省 10 + 角标行 +17）→ 643，余 24；失败原因行净 +8 → 644，余 23。
    ///   同档 mini（375×812，topInset 50，底部 34）：636 − 20 + 50 + 34 = 700 ≤ 812。
    /// - standard（390×844，topInset 47，底部 34；本轮一字不动）：
    ///   47 + 49 + 6 + 254 + 8 + 180 + 8 + 60 + 10 + 36 + 8 + 32 + 8 + 50 + 8 + 61 + 34 = 859 > 844，
    ///   纸面超 15pt = 顶边口径差 8（纸面顶 47、实测顶 39）+ 390×844 按纠正后实账超 7
    ///   （固定段 671 + 180 = 851 > 844）；402×874 用户真机实账 851 ≤ 874，余 23，
    ///   见 PlayerView 文件底 r27 段落与交回（standard 本轮不动，390×844 的 7pt 待定夺）。
    /// - large（430×932，topInset 59，底部 34；r27 只压有角标态）：
    ///   59 + 49 + 6 + 280 + 8 + 210 + 8 + 67 + 10 + 36 + 8 + 32 + 8 + 51 + 8 + 68 + 34 = 942 > 932，
    ///   纸面超 10pt 全是顶边口径差（纸面顶 59、实测顶 39，差 20；实账固定段 712 + 210
    ///   = 922 ≤ 932，余 10）。状态角标净 +7 → 949，超 17（口径差 20 − 实账余 3，
    ///   实账 719 + 210 = 929 ≤ 932）。
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
    /// r27 压缩：compact 168 → 154（只动 compact 档，见 PlayerView 文件底
    /// r27 段落；standard / large 一字不动）。
    static func coverItem(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 154
        case .standard: return 188
        case .large: return 208
        }
    }

    /// 封面流轨道高（含倒影）。内部账：单张 + 间距 8 + 倒影（单张 × 0.3）：
    /// compact 154 + 8 + 46.2 = 208.2 ≤ 209；
    /// standard 188 + 8 + 56.4 = 252.4 ≤ 254；
    /// large 208 + 8 + 62.4 = 278.4 ≤ 280。
    /// r27 压缩：compact 轨道 232 → 209（省 23pt，只动 compact 档）。
    static func coverTrackHeight(_ tier: PlayerSizeTier) -> CGFloat {
        switch tier {
        case .compact: return 209
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
