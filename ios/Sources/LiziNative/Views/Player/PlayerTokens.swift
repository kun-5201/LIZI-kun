import SwiftUI

/// 播放页设计令牌。
///
/// 共享令牌（纸面 / 墨色 / accent / 字号 / 圆角）复用首页工人已建的
/// `LiziTokens`（`Views/Home/DesignTokens.swift`，同样照抄壳版
/// `public/tokens.css`），全 App 只有一个 accent，不另起第二套色板。
/// 这里只补播放页自己用的：深色页前景（壳版 `body.is-now` 的白字透明度）、
/// 封面取色缺省三色调、dock 渐变两端、播放页固定尺寸。
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

    // MARK: - 播放页固定尺寸（app.css / 任务书）

    /// 封面流轨道高（`.cf__track`）。
    static let coverFlowTrackHeight: CGFloat = 254
    /// 封面流拉起歌词后面板收小后的轨道高。
    static let coverFlowTrackHeightCompact: CGFloat = 198
    /// 单张封面（`.cf__item`）。
    static let coverFlowItemSize: CGFloat = 188
    static let coverFlowItemSizeCompact: CGFloat = 148
    /// 底部 dock 高（`--dock-h: 76px`）。
    static let dockHeight: CGFloat = 76
    /// 传输键（窄屏 `.ntr` 52px，大播放键 64px）。
    static let transportButtonSize: CGFloat = 52
    static let transportPlaySize: CGFloat = 64

    // MARK: - 时长格式化（mm:ss，tokens.css --font-mono 的等宽数字意图）

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
