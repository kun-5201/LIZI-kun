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
    /// 顶栏（r29 task 5 起竖屏固定 44pt，r27 实测 49pt，见 PlayerView.topBar
    /// 注释；本函数 topBarButton 的 44/48/52 只剩横屏胶囊在用）+ 间隙 6
    /// + 封面流 + 间隙 8 + 歌名块（歌名行高 ≈ titleSize × 1.25）
    /// + 间隙 8 + 歌词区 + 间隙 8 + 歌手块（副标题行高 ≈ subtitleSize × 1.3，
    /// 有状态行时再加角标行；r29 task 6：歌名提到歌词区之上、歌手挪到
    /// 歌词区之下，原来 titleBlock 的位置）
    /// + 间隙 8 + 底部三排（第 3 排 32/26 + 间隙 8/2 + 第 2 排进度条 50/46
    /// + 间隙 8/2 + 最下面一排 61/42，标准/compact；large 32/51/68；
    /// dock 上间隙 8，compact 4）
    /// + 底部安全区（Home Indicator）。
    /// r29 task 5/6 纠正：纸面账 standard/large 里的「第二行 36」是已删
    /// 第二行（PlayerSecondRow.swift，r28 删文件；dock 只有三排），r27
    /// 换 dock 时旧账没摘掉；摘掉后 standard/large 纸面账也过线了（见下）。
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
    ///   20 + 44 + 6 + 209 + 8 + 35 + 8 + 150 + 8 + 17 + 10 + 4 + 26 + 2 + 46 + 2 + 42 + 0 = 637 ≤ 667，余 30。
    ///   状态角标行净 +7（间距省 10 + 角标行 +17）→ 644，余 23；失败原因行净 +8 → 645，余 22。
    ///   同档 mini（375×812，topInset 50，底部 34）：637 − 20 + 50 + 34 = 701 ≤ 812。
    /// - standard（390×844，topInset 47，底部 34）：
    ///   47 + 44 + 6 + 254 + 8 + 40 + 8 + 180 + 8 + 18 + 10 + 8 + 32 + 8 + 50 + 8 + 61 + 34 = 824 ≤ 844，余 20。
    ///   纸面 824 与实账 816（固定段 636 + 180）差 8 = 顶边口径差（纸面顶
    ///   47、实测顶 39）；402×874 用户真机实账 816 ≤ 874，余 58；390×844
    ///   同档也过（816 ≤ 844，余 28），r27 的「390×844 超 7pt 待定夺」随
    ///   第二行 36pt 摘掉而消失。有角标 +22 → 纸面 846，超 2（口径差 8 −
    ///   实账余 6；实账 658 + 180 = 838 ≤ 844，余 6），只纸面超、实账不过。
    /// - large（430×932，topInset 59，底部 34）：
    ///   59 + 44 + 6 + 280 + 8 + 45 + 8 + 210 + 8 + 20 + 10 + 8 + 32 + 8 + 51 + 8 + 68 + 34 = 907 ≤ 932，余 25。
    ///   纸面 907 与实账 887（固定段 677 + 210）差 20 = 顶边口径差（纸面顶
    ///   59、实测顶 39）。状态角标净 +7 → 914，余 18（实账 684 + 210 = 894，
    ///   余 38）；失败原因行净 +8 → 915，余 17。
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

    /// 控制行小图标字号（上一首/下一首/队列列表）。
    /// r28：一字不动——v4 dock（PlayerBottomDock.transportIconFont）
    /// 共用它。（r35-7：传统播放页控制行 PlayerControlRow 已删。）
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
