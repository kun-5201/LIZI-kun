import SwiftUI
import UIKit

/// 首页（大厅）：顶栏 + Hero 大卡 + 铺色面板（平台条 + 跑马带/环）+ 本地音乐。
/// r26（用户 2026-11-20 22:39–22:40 决定）：首页 5 个来源 chips
/// （每日推荐 / 精选 / 我的喜欢 / 我收藏的歌单 / 电台）全删，只留每日推荐；
/// 来源切换逻辑、首屏之下的 rail 行、rail 登录墙随 chips 一起删掉。
/// 删掉的 4 个来源的新显示方法等图纸批了再接线，不在这里先占位置。
/// 每日推荐本身不动：数据链（`NativeBridge.dailyRecommend`）与面板里的
/// 环/跑马带渲染（`HomeCoverRingView`）原样保留。
///
/// r28（用户 2026-11-21 01:21–01:38 定稿）：删掉的 4 个来源加回，
/// 不再是 chips——每日推荐面板改成上下翻页（一次一个栏目，共 6 栏，
/// 见 `HomeRailPage`（HomeViewModel.swift）与本文件 `pagerHeader` /
/// `pagerContent` / `pagerDragGesture`）：每日推荐 → 精选 → 用户收藏 →
/// 喜欢的歌曲 → 用户创建的歌单 → 电台。平台条仍固定显示「每日推荐」
/// （PlatformStripView.swift 不许动），栏目名以栏头为准；
/// 内容区内的上下滑归切栏，横向拖动仍归环（开环/切歌），改尺寸仍归
/// 分界手柄，面板外的滑动照旧滚整页。
///
/// r30（用户 2026-11-21：首页 v4 图定稿，见 ~/workspace/lizi-home-daily-v4.png）：
/// r28 的上下翻页器整套撤掉——`HomeRailPagerView.swift` 删文件，
/// 本文件里的栏头（栏目名 + 圆点 + n/6 + 上/下钮）、`pagerContent`、
/// `pagerDragGesture`、`pagerDragY` / `pagerWentNext` 全删；
/// 来源改成点平台条标题弹小菜单切（壳版 `#hall-src-menu` 思路：
/// 浮层列 6 个来源，点选即切，当前来源打勾），栏内容随来源换
/// （每日推荐 = 环/跑马带，其余 5 栏 = 原 `HomeRailPageView` 的 rail 列表，
/// 原样搬进本文件 `RailSourceListView`，只改名、不改行）；
/// 平台条标题 24pt→19pt、图标 28pt→26pt、搜索字形 18pt→19pt
/// （逐帧规格 + v4 图量）；面板取色 r28 已接好（见 `.task(id:)` 与
/// 文件尾 `AlbumTone`），本轮核实后不动；面板高度账不变
/// （栏头 28pt 撤掉后内容区多出 36pt 余量，`panelContentH` 公式不动）。
/// 本地音乐仍在面板下方、首屏可见，不动。
///
/// r28（用户 2026-11-21 01:52：39.6s 套壳视频逐帧重做，见
/// verification/shell-video-39s-home-3d.md；另 01:57「环只手滑展开」、
/// 01:58「面板跟专辑取色」两条澄清）：
/// 首页按壳版视频改——Hero 默认约 152pt（竖屏 fraction 0.215；
/// 旧模板 v2 的一半屏 382pt 已作废）、面板按内容封顶约 407pt
/// （标准档，flatCard+217）、本地音乐露在首屏；竖屏顶栏与 Hero
/// 之间 46pt、Hero 与面板之间 27pt（手柄居中压在 27pt 缝里）；
/// 面板底色不再是平台色 10% tint，改按在播专辑取色（`AlbumTone`，
/// 壳版 paintTone/applyTone 同款：封面 OKLCH k=4 聚类取 5 档，
/// stops[2]/[3]/[4] → tone-a/b/c；没封面/取色失败走默认色
/// #5b5bd6/#b04f8c/#2f6f8f；切歌即换）。
/// 模板 v2 的「两块拼满整屏 / 本地音乐一个像素都不许露首屏」已作废；
/// 横屏几何不动（顶栏 64 + 间距 26 + Hero 180 + 间距 20 + 面板 140）。
///
/// r24 首页两卡拖动改尺寸：Hero 底边 / 面板顶边接缝处一条 28pt 高分界手柄
/// （r28：竖屏两块之间是 27pt 间隙，手柄居中压在缝里、上下各探进约 0.5pt，
/// 中间一条 49×5 圆角胶囊——39.6s 视频实测宽约 90px ≈ 49pt），竖直拖动改
/// 两块高度分配，松手停在哪就是哪（不回弹、不吸附、不贴靠档位）；Hero 与
/// 面板高度之和 ≤ contentH（r28：面板按内容封顶后余下是本地音乐，见 body），
/// 尺寸按方向分别持久化，见下面
/// heroFractionPortraitKey / heroFractionLandscapeKey（竖屏默认 0.215、
/// 横屏默认 9/16）；拖动中只改 @State、不写 UserDefaults，松手才写当前
/// 方向的 key。上下限见 body 里 minHeroH / minPanelH 的注释（数都从
/// HeroCardView / PlatformStripView / HomeCoverRingView
/// 的代码量出来，不是拍脑袋）。拖动时外层 ScrollView 用
/// `.scrollDisabled(dragging)` 停滚；手柄 28pt 高只盖住 Hero 底边 0.5pt
/// 与面板顶边 0.5pt——Hero 播放钮底边在 Hero 底边之上 20pt、平台条从面板
/// 内 10pt 才起（图标/搜索钮更往下），手柄盖住的区域没有可点控件；
/// 点按因 DragGesture(minimumDistance: 6) 未触发而失败透传，不挡
/// Hero 整卡点按进播放页与面板顶的平台条点按。
///
/// 布局（模板 v2，已确认：~/workspace/lizi-home-template-portrait.png /
/// lizi-home-template-landscape.png；竖屏与横屏都是上下叠，横屏左右分已作废）：
/// 1. 顶栏（固定在滚动区之外，r20 修）：一行，左列设置齿轮 + 搜索
///    （38pt 平面按钮，字形按模板画完整：齿轮 30pt、搜索 28pt，不裁切），
///    品牌居中（LI 标记 + LIZI 字标 34×15 + kun 斜体 11px，都是代码画的：
///    LI 标记和 LIZI 按壳版 `index.html` 内联 SVG 坐标用 SwiftUI Path 画，
///    kun 是 Fraunces 斜体 Text；不是抠图、不是图片资源）。
///    竖屏：行顶距屏顶 31pt（品牌纵向中心 = 31+32 = 63pt，灵动岛底下约 7pt，
///    照用户 04:51 截图量）；横屏：行顶就是屏顶（横屏顶上没有灵动岛，
///    品牌中心 = 32pt）。横屏左列按 leading 安全区（灵动岛在侧边）往里收，
///    按钮不被屏幕圆角裁掉（用户 05:08「设置和搜索按钮要画完整」）。
/// 2. 竖屏按壳版视频排（r28；402×874 档）：顶栏区 95 + 间距 46 +
///    Hero 152 + 间隙 27 + 面板（内容封顶 407）= 727，余下是本地音乐
///    （壳版视频里本地音乐就露在首屏）；横屏 Hero 横幅 + 面板上下叠
///    （932×430 档：顶栏 64 + 间距 26 + Hero 180 + 间距 20 + 面板 140 = 430）。
///    Hero 高 = contentH × fraction（竖屏默认 0.215，见 loadHeroFraction），
///    面板取剩下那份再按内容封顶（竖屏 flatCard+217，横屏 (屏高−110)×7/16）。
///    面板内容（条 48 + 栏头 28 + 环带 242 + 提示行 27）比横屏面板 140 高，
///    差额由面板内竖滑消化，不硬凑；竖屏面板封顶后内容正好放下。
///    平台条钉在面板顶，不进 ScrollView（r23h：放歌后 / 手指竖滑都顶不走它）。
/// 3. 本地音乐区在面板之下（竖屏露在首屏，见上；文件夹卡片 + 导入按钮，
///    见 LocalMusicView.swift）。段间距 24；底部留白 50
///    （16 净空 + 34 Home Indicator，底部安全区已忽略）。
/// 4. 铺色面板（壳版 `#hall-plat`，圆角 22，内边距 10）：
///    平台条（r30：左列当前来源标题 19pt 粗体 + 7 图标 26pt 间距 5，
///    高 48，右端搜索 19pt；点标题弹来源小菜单）
///    → 来源内容（每日推荐 = 3D 封面环 HomeCoverRingView，平面跑马带常态；
///    其余来源 = rail 列表 RailSourceListView），同一块圆角面板里，
///    顺序与壳版 bar → marquee 一致。
///    面板底色 r28 起按在播专辑取色（`AlbumTone`，见文件头 r28 节；
///    旧「平台品牌色 10% 淡 tint」已作废）。
///    壳版面板 min-height 按条 + gap 8 + marq 228 + 内边距 20 计
///    （壳版原值见 PlatformStripView 注释；原生条已是 48，见下 minPanelH）；
///    原生面板内容是视频尺寸环卡（平面带高 card+52，标准档 242，
///    另加提示行 6+27、底座内边距 20 与栏头 28），标准档内容约 407。
/// 5. 本地音乐区在最末（模板 v2）：文件夹卡片（点开是文件列表，点文件播放）
///    + 「导入本地音乐」按钮；没歌时空态，不编假文件。
///    封面只用真数据：Hero 封面 = 正在播那首歌的封面，面板封面 = 当前平台
///    每日推荐的真封面；模板图里的示例封面不进包、不当数据。
///
/// 设置齿轮的决定（P3-C）：点按进设置页（AppNavigation.settings），
/// P1 的空态提示横幅已撤掉。
struct HomeView: View {
    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation
    @StateObject private var viewModel = HomeViewModel()
    /// 首页环状态机（r21）：平面带与全屏环覆盖层共用（见 HomeCoverRingView 文件头）。
    @StateObject private var ringModel = HomeCoverRingModel()
    /// 本地音乐区块显示开关（#48：键与 `SettingsStore.localMusicShown`
    /// 同键 `lizi.local.show`，默认开；@AppStorage 直接监听 UserDefaults
    /// 变化，设置页拨开关后回首页即生效，不依赖 SettingsStore 实例）。
    @AppStorage("lizi.local.show") private var localMusicShown = true

    // MARK: - r24 首页两卡拖动改尺寸（分界手柄 + 持久化）

    /// 持久化 key（r24，就这两个，不另起）：竖屏 / 横屏各记各的 fraction。
    /// r28：竖屏 key 加 `.r28` 后缀——旧 key 存的是模板 v2 几何下标定的
    /// fraction（用户手机上 r26 截图是 0.53，对应旧 Hero 382pt）；r28
    /// 几何全变了（gapTop 46、gapMid 27、面板封顶），旧值按新几何算出来
    /// 不是视频比例，必须按新默认 0.215 重起；用户仍可拖动手柄改，改完
    /// 记新 key。横屏几何没变，key 不动。
    private static let heroFractionPortraitKey = "lizi.native.home.heroFraction.portrait.r28"
    private static let heroFractionLandscapeKey = "lizi.native.home.heroFraction.landscape"

    /// 读存值：读不到（double(forKey:) 缺键回 0）或非法（非有限、≤0、≥1）
    /// 回落默认——竖屏 0.215（r28：39.6s 视频 Hero 约 152pt，
    /// contentH 706 档 152/706 ≈ 0.215；旧 0.5 已作废）、横屏 9/16
    /// （0.5625，与 r23 前的模板公式同值）。
    /// 读出后在 body 里再按当前 contentH 与上下限夹一次（见 minFrac / maxFrac）。
    private static func loadHeroFraction(landscape: Bool) -> CGFloat {
        let fallback: CGFloat = landscape ? 9.0 / 16.0 : 0.215
        let raw = UserDefaults.standard.double(
            forKey: landscape ? heroFractionLandscapeKey : heroFractionPortraitKey)
        guard raw.isFinite, raw > 0, raw < 1 else { return fallback }
        return CGFloat(raw)
    }

    /// Hero 占 contentH 的比例，竖屏 / 横屏各一个 @State（UserDefaults 初始化，
    /// 见 loadHeroFraction；旋转后按新方向的存值恢复，fraction 是相对值，
    /// contentH 一变高度自动重算）。拖动中只改这里、不写 UserDefaults，
    /// 松手才写当前方向的 key。
    @State private var heroFractionPortrait: CGFloat = HomeView.loadHeroFraction(landscape: false)
    @State private var heroFractionLandscape: CGFloat = HomeView.loadHeroFraction(landscape: true)
    /// 正在拖分界手柄：外层 ScrollView `.scrollDisabled(dragging)` 停滚。
    @State private var dividerDragging = false
    /// 本次拖动的起始 Hero 高（onChanged 第一次进来时记，松手清掉；
    /// translation 是从手势起点累计的，必须配一个固定的起点算 newHeroH）。
    @State private var dragStartHeroH: CGFloat?
    /// r30 来源小菜单是否打开（点平台条标题开，点菜单外 / 选来源后关）。
    @State private var sourceMenuShown = false
    /// r28 面板取色：正在播那首歌的专辑色板（`AlbumTone`，见文件尾；
    /// 默认 tone-a/b/c #5b5bd6/#b04f8c/#2f6f8f）。`.task(id:)` 跟
    /// toneSourceURL 走，切歌即重算；没封面/取色失败回默认色。
    @State private var panelTone = AlbumTone.fallback

    /// r28 面板取色的源：正在播那首歌，没在播时取 Hero 显示的上次播放
    /// （与 Hero 封面同一首，面板色与 Hero 专辑一致；两首都没有时 nil）。
    private var toneSourceURL: URL? {
        (playback.currentTrack ?? viewModel.lastTrack)?.coverURL
    }

    var body: some View {
        GeometryReader { outer in
            // r20 顶栏修复：topBar 原来是 ScrollView 里的第一行，往下滚就滚出
            // 屏幕——QQ 每日推荐有真内容可翻，用户一翻搜索/设置就不见了；
            // 其它平台每日为空、没东西可翻，所以显得只有 QQ 出问题。
            // 根因与平台切换逻辑无关（selectPlatform 对 7 家同一套），所以
            // 不修 ViewModel、不加平台分支：只把 topBar 固定在滚动区之外，
            // 7 个平台同一套固定顶栏。
            // 模板 v2 几何（屏顶坐标；上下安全区都已忽略，outer.size = 整屏）：
            // r28：竖屏按壳版视频排——顶栏区 95 + 间距 46 + Hero 152 +
            // 间隙 27 + 面板（内容封顶 407）= 727，余下是本地音乐
            // （壳版视频里本地音乐就露在首屏）；横屏：顶栏 64，
            // 间距 26，Hero 横幅 (430−110)×9/16 = 180，间距 20，
            // 面板 (430−110)×7/16 = 140，底边同样是屏底边。
            // 两块左右各留 16pt 边（模板量）；横屏顶栏左列按 leading 安全区
            // 往里收（见 topBar），Hero/面板本身不收（它们的顶在 90pt 以下，
            // 碰不到屏幕圆角）。
            let isLandscape = outer.size.width > outer.size.height
            let topPad: CGFloat = isLandscape ? 0 : 31
            let topBarH: CGFloat = 64
            let gapTop: CGFloat = isLandscape ? 26 : 46
            let gapMid: CGFloat = isLandscape ? 20 : 27
            let contentH = outer.size.height - topPad - topBarH - gapTop - gapMid
            // r24 两卡高度分配：heroH = contentH × fraction（按方向取各自的
            // @State），panelH = contentH − heroH，总高不变、首屏仍拼满。
            // tier 在这里算一次，minPanelH 与 dailyPanel 共用。
            let tier = PlayerTokens.sizeTier(for: outer.size, topInset: outer.safeAreaInsets.top)
            // r24 上下限（数都从代码量出来，见各行注释；fraction 的合法夹取
            // 区间就是 [minHeroH, maxHeroH] 换算成的比例）：
            // - minHeroH：Hero 内上下内边距 20+20（HeroCardView
            //   `.padding(.vertical, 20)`）+ 顶行 30（锁钮 30×30 圆钮，
            //   徽章 13pt 字行高约 16，取大者 30；无歌时顶行是空的，
            //   按有歌的最坏情况算）+ 底行：歌名行高 ≈ titleSize×1.25
            //   （PlayerTokens 文件头同款行高约定）+ 间距 8
            //   （底行 VStack spacing 8）+ 副标题行高 ≈ 15×1.3 ≈ 20
            //   （播放钮 ⌀40 小于底行高，不计）；顶行与底行之间的 Spacer
            //   可压到 0，不计。r28 titleSize 26：
            //   40+30+32.5+8+20 = 130.5→131（横竖屏同值）。
            //   封面是铺满的底图、无固定高，不占下限。
            let titleSize: CGFloat = 26
            // r24 构建修（run 44646659508）：原来 `ceil(40 + 30 + titleSize * 1.25 + 8 + 17)`
            // 一整串混着 Int 字面量 + Double 字面量 1.25，编译器报
            // "unable to type-check this expression in reasonable time"。
            // 拆成两步、每步只有一个 CGFloat 锚点，字面量跟着它推断。
            let titleLineH: CGFloat = titleSize * 1.25
            let minHeroH: CGFloat = ceil(40 + 30 + titleLineH + 8 + 20)
            // - 平面带一排封面卡宽（HomeCoverRingView 分档表：compact 180 /
            //   standard 190 / large 209，≈0.486vw，39.6s 视频量），minPanelH 按 tier 走。
    /// r24 构建修（run 44656645107）：`let flatCard` + `switch` 语句在
    /// GeometryReader 的 @ViewBuilder 闭包里，分支产出 `()` 不符合 View，
    /// 编译器报 "type '()' cannot conform to 'View'"。改成三元表达式
    /// （同理下面 minPanelH 的 if/else 也改成三元，免得修完一个又冒一个）。
    let flatCard: CGFloat = tier == .compact ? 180 : tier == .standard ? 190 : 209
            // - minPanelH：面板内边距上下 10+10（dailyPanel `.padding(10)`）
            //   + 平台条 48（PlatformStripView `.frame(height: 48)`）
            //   + 面板 VStack 间距 8（条与下一行之间）
            //   + 至少一排环封面 flatCard（歌名/歌手行与「展开 3D 环」提示行
            //   都在面板内竖滑区里，面板是定高窗、裁断是模板原意，不计入下限；
            //   标准档：20+48+8+190 = 266）。
            //   r26：chips 行已删，竖屏下限不再加 chips 32 + 间距 8。
            //   横屏面板默认只有约 140 高，只要求条之外再露约 1/4 张封面
            //   （flatCard/4，标准档 190/4 ≈ 47.5，封面露一角、能认出是封面带；
            //   模板默认露 70，标准档下限 20+48+8+47.5 = 123.5→124 < 140，
            //   默认值仍在合法区间里）。
            // r24 构建修：同上，if/else 赋值改三元表达式。
            let ringPeek: CGFloat = flatCard / 4
            let minPanelH: CGFloat = isLandscape
                ? ceil(20 + 48 + 8 + ringPeek)
                : 20 + 48 + 8 + flatCard
            // - maxHeroH = contentH − minPanelH。内容极矮时两条下限打架：
            //   保 Hero 下限（歌名 + 播放钮必须完整），面板取剩下的
            //   （仍有条 + 一角封面），不让区间倒挂（r28：667×375 档
            //   contentH 265 ≥ minHeroH 131 + minPanelH 129 = 260，
            //   已不打架；max() 只是兜底）。
            let maxHeroH = max(minHeroH, contentH - minPanelH)
            let minFrac = minHeroH / contentH
            let maxFrac = maxHeroH / contentH
            let storedFrac = isLandscape ? heroFractionLandscape : heroFractionPortrait
            let fraction = min(max(storedFrac, minFrac), maxFrac)
            let heroH = contentH * fraction
            // r28：面板高按内容封顶（壳版视频：面板约 336–407pt，本地音乐露在
            // 首屏；旧「两块拼满整屏」已作废）。内容高 = 内边距 20 + 条 48 +
            // 间距 8 + 内容区（每日内容：底座内边距 20 + 带 flatCard+52
            // + 间距 6 + 提示行 27 = flatCard+105，再加 r30 栏头撤掉后
            // 多出的 36pt 余量）= flatCard + 217（标准档 407；
            // compact 397、large 426；公式不动，只改账）。
            // 横屏面板 140 本来就小于内容高，封顶不触发。拖大 Hero 后面板按
            // split 收缩（低于封顶），不受封顶影响；拖小 Hero 后面板停在封顶，
            // 余下是本地音乐，不留空。
            let panelContentH: CGFloat = flatCard + 217
            let panelH = min(contentH - heroH, panelContentH)
            let blockW = outer.size.width - 32
            VStack(spacing: 0) {
                topBar(topPad: topPad, leadingPad: isLandscape ? outer.safeAreaInsets.leading + 16 : 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // r28：竖屏 Hero + 面板 + 本地音乐按壳版视频排
                        // （顶栏 95 + 间距 46 + Hero 152 + 间隙 27 + 面板 407，
                        // 本地音乐露在首屏；旧「两块拼满、本地音乐不露首屏」
                        // 已作废，见文件头 r28 节）。
                        VStack(alignment: .leading, spacing: gapMid) {
                            HeroCardView(
                                width: blockW,
                                viewHeight: outer.size.height,
                                height: heroH,
                                titleSize: titleSize,
                                viewModel: viewModel
                            )
                            .padding(.horizontal, 16)

                            // 铺色面板（壳版 `#hall-plat`）：平台条 → 来源内容
                            // （每日推荐 = 环/跑马带，其余来源 = rail 列表），
                            // 同一块圆角面板里，顺序与壳版 bar → marquee 一致。
                            // 圆角 22、内边距 10（壳版 `.hall-plat` / plat-face）；
                            // 底色 = 当前平台品牌色 10% 淡 tint（壳版是平台色满铺，
                            // 原生浅色卡片 + 墨字只能淡 tint 近似，见文件头）。
                            // r21 起环的平面态就是每日跑马带，HomeView 不再单独挂
                            // DailyMarqueeView（两处并存会叠两条一样的带）。
                            dailyPanel(
                                width: blockW,
                                height: panelH,
                                isLandscape: isLandscape,
                                tier: tier
                            )
                            // r22l 编译修：231 行 tier 类型错导致这行
                            // dailyPanel 调用的结果类型推不出来，`.horizontal`
                            // 跟着报「cannot infer contextual base」——
                            // 是 231 行的级联，不是这行本身写错；写明
                            // Edge.Set 后即使类型再出问题也不会连带误报，
                            // 布局与数值与原来完全一致。
                            .padding(Edge.Set.horizontal, 16)
                        }
                        .padding(.top, gapTop)
                        // r24 分界手柄（见文件头）：叠在 Hero 底边 / 面板顶边
                        // 接缝处，中心在 gapTop + heroH + gapMid/2（竖屏
                        // gapMid = 27，手柄居中压在 27pt 间隙正中、上下各探进
                        // Hero / 面板约 0.5pt；横屏 gapMid = 20，同理）。
                        // 触摸区 28pt 高、宽 blockW，与两块同宽；
                        // 中间只画一条 49×5 圆角胶囊（低对比度，视频实测宽 49pt）。
                        // 透传：手柄探进两块的约 0.5pt 里没有可点控件——Hero
                        // 播放钮底边在 Hero 底边之上 20pt（40 圆钮 + 底内边距
                        // 20，见 HeroCardView），面板顶 0.5pt 内只有面板内边距
                        // （条从面板内 10pt 才起，图标与搜索钮更往下，
                        // 见 PlatformStripView）；
                        // 点按因 DragGesture(minimumDistance: 6) 未触发而失败
                        // 透传，Hero 整卡点按与平台条点按不受影响。
                        // 横向为主的拖动不改尺寸（Hero 左右滑切歌只在接缝上下
                        // 约 0.5pt 的窄条里会被手柄先接到，见交回说明）。
                        .overlay(alignment: .top) {
                            HomeResizeHandle()
                                .frame(width: blockW, height: 28)
                                .offset(y: gapTop + heroH + gapMid / 2 - 14)
                                .gesture(
                                    DragGesture(minimumDistance: 6)
                                        .onChanged { value in
                                            if dragStartHeroH == nil { dragStartHeroH = heroH }
                                            guard abs(value.translation.height) >= abs(value.translation.width) else { return }
                                            dividerDragging = true
                                            let startHeroH = dragStartHeroH ?? heroH
                                            let newHeroH = min(max(startHeroH + value.translation.height, minHeroH), maxHeroH)
                                            let newFraction = newHeroH / contentH
                                            if isLandscape {
                                                heroFractionLandscape = newFraction
                                            } else {
                                                heroFractionPortrait = newFraction
                                            }
                                        }
                                        .onEnded { _ in
                                            dividerDragging = false
                                            dragStartHeroH = nil
                                            // 松手即停：只写当前方向的 key，不回弹、
                                            // 不吸附、不贴靠档位；拖动中不写 UserDefaults。
                                            UserDefaults.standard.set(
                                                Double(isLandscape ? heroFractionLandscape : heroFractionPortrait),
                                                forKey: isLandscape ? Self.heroFractionLandscapeKey : Self.heroFractionPortraitKey
                                            )
                                        }
                                )
                                .accessibilityLabel("调整 Hero 与面板高度")
                                .accessibilityHint("上下拖动改变两块高度，松手即停")
                                .accessibilityAdjustableAction { direction in
                                    let step: CGFloat = 0.05
                                    let next = min(max(fraction + (direction == .increment ? step : -step), minFrac), maxFrac)
                                    if isLandscape {
                                        heroFractionLandscape = next
                                    } else {
                                        heroFractionPortrait = next
                                    }
                                    UserDefaults.standard.set(
                                        Double(next),
                                        forKey: isLandscape ? Self.heroFractionLandscapeKey : Self.heroFractionPortraitKey
                                    )
                                }
                        }

                        // 面板之下：本地音乐区（r28：竖屏露在首屏，不再是
                        // 「下滑才看到」；见文件头 r28 节）。
                        // 本地音乐排在最末；段间距 24 与上面同档。
                        // r26：首屏之下的 rail 行随来源 chips 一起删掉
                        // （RailRowView + 「我的专辑」入口卡），只剩本地音乐。
                        VStack(alignment: .leading, spacing: 24) {
                            // #48：按「在首页显示」开关（`lizi.local.show`，
                            // 默认开）显示/隐藏本地音乐区块；关了整块消失、
                            // 不留占位，导入功能不受影响。
                            if localMusicShown {
                                LocalMusicSectionView()
                            }
                        }
                        .padding(.top, 24)
                        // 底部留白 50 = 16 净空 + 34 Home Indicator
                        // （底部安全区已忽略，见 ignoresSafeArea；滑到底时
                        // 本地音乐导入钮离 Home Indicator 还有 16pt 净空）。
                        .padding(.bottom, 50)
                    }
                }
                // r24：拖分界手柄时外层整页 ScrollView 不许跟着滚
                // （dividerDragging 只在竖向拖动里置 true，松手清掉；
                // minOS 16.2 可用，本项目已有 LyricsPanelView 同款用法）。
                .scrollDisabled(dividerDragging)
                .background(LiziTokens.paper)
            }
            // r21：环的纵向锚点用这个坐标空间量（平面带把自己的 frame 报到
            // "liziHome" 里，覆盖层按同一坐标系把环摆到带原来的位置）。
            .coordinateSpace(name: "liziHome")
            // r21：全屏环覆盖层（展开态；ScrollView 之外，变暗盖住整页）。
            .overlay {
                if ringModel.ringPhase != .closed {
                    HomeRingOverlayView(model: ringModel)
                }
            }
            .background(LiziTokens.paper)
        }
        // 模板 v2：顶栏整行按屏顶定位（品牌中心竖屏 63pt、横屏 32pt），
        // 不按安全区顶；忽略顶部与底部安全区后
        // GeometryReader 原点 = 屏顶、size = 整屏（390×844 档 viewHeight
        // 从 781 变 874，Hero 高随之变，见驱动 2b；sizeTier 只看宽度，
        // 不受影响；"liziHome" 坐标系与环覆盖层同系，相对位置不变）。
        // 底部留白由内容自己留 50（16 净空 + 34 Home Indicator），
        // 不靠系统安全区。
        .ignoresSafeArea(edges: [.top, .bottom])
        .task {
            // r26：首页启动只拉每日推荐。原来这里还刷一次登录态
            // （`LoginStore.refresh`），是给 rail 登录墙（`LoginGate`）
            // 备的——chips 与 rail 行已删，登录墙一并删掉，不再刷。
            await viewModel.initialLoad()
            // r22j 平台管理：当前选中平台被取消勾选时，自动切到第一个勾选
            // 的平台（走 selectPlatform 五步，不另写切台；选中平台被隐藏是
            // 设置页改完回首页才有的状态，initialLoad 读完持久化选择后
            // 在这里一次性纠正）。visiblePlatforms 只是 UserDefaults 只读，
            // 不写、不缓存；回首页时 viewModel 新建，读到的就是最新勾选。
            if !viewModel.visiblePlatforms.contains(viewModel.selectedPlatform),
               let first = LiziPlatforms.all.first(where: { viewModel.visiblePlatforms.contains($0.id) }) {
                viewModel.selectPlatform(first.id, playbackStore: playback)
            }
        }
        .task(id: toneSourceURL) {
            // r28 面板取色（壳版 paintTone/applyTone 同款，见文件尾 AlbumTone）：
            // 正在播那首歌的封面取 5 档色板，stops[2]/[3]/[4] → tone-a/b/c；
            // coverURL 一变（切歌）任务重开，旧任务取消、旧结果不回写；
            // 没封面 / 取图失败 / 取色失败 → 默认色。取图复用
            // CoverImageLoader 的进程内缓存（ProxyImageView 同一条），
            // 不另发请求；32×32 取样 + k=4 聚类是毫秒级，不另起线程。
            guard let url = toneSourceURL else {
                panelTone = .fallback
                return
            }
            guard let image = await CoverImageLoader.shared.image(for: url),
                  url == toneSourceURL,
                  let tone = AlbumToneExtractor.tone(from: image) else {
                if url == toneSourceURL { panelTone = .fallback }
                return
            }
            if url == toneSourceURL { panelTone = tone }
        }
        .onChange(of: playback.currentTrack) { track in
            if let track = track {
                Task { @MainActor in viewModel.notePlayed(track) }
            }
        }
    }

    /// 每日推荐铺色面板（壳版 `#hall-plat` 内容；r28：底色是专辑取色渐变，
    /// 见 `panelTone` 与文件尾 `AlbumTone`）：
    /// 圆角 22、内边距 10、底色 tone-a→tone-b→tone-c 对角渐变；
    /// 只有环在窗内竖滑（横屏面板 140 比内容矮得多；模板里面板封面本来
    /// 就是齐底边裁断的）。顺序：条 → 内容（r30：栏头已删，条之下直接是
    /// 一次一栏的内容区；r28 分页器的栏头/圆点/上下钮/竖滑切栏全撤，
    /// 来源改点条标题弹小菜单切，见 `sourceMenuOverlay`）。
    /// r23h：平台条钉在面板顶、不进竖滑 ScrollView——
    /// 面板是定高窗、内容比窗高，放歌后环内容一换（每日 → 队列）或手指
    /// 在面板里竖滑，ScrollView 的偏移会把条顶出窗外、再也滑
    /// 不回来（07:09 真机：条 + chips 全没了、环还在）；钉在外面后偏移
    /// 再怎么变也顶不走它。
    /// 真机风险：面板内竖滑与环的上滑展开手势竞争——环的展开用 UIKit
    /// pan recognizer（见 HomeCoverRingView，r21 教训后不再用 SwiftUI
    /// DragGesture），它与外层 ScrollView 竖滑共存；现在多了一层面板内
    /// ScrollView，展开手势是否仍优先，要真机验（见清单 D19）。
    /// r28：环的上滑展开已删（r24 起竖向占优的手势由环的识别器自毁、
    /// 交还 ScrollView；横向才是开环）。r30：面板内容区竖滑不再切栏
    /// （分页器已撤），竖滑归外层 ScrollView 滚整页、横滑归环开环、
    /// 点按播歌/进详情；横屏面板只有约 140 高，条占掉大半后 rail 栏
    /// 只剩约一行的位置，「查看全部」进整页看全量，
    /// 见 `RailSourceListView`（原 `HomeRailPageView`）的文件头注释。
    /// r22l 编译修：真类型名是 PlayerTokens.PlayerSizeTier
    ///（PlayerTokens.swift 里 `enum PlayerSizeTier`，r20 约定名），
    /// 之前写的 SizeTier 不存在。
    private func dailyPanel(
        width: CGFloat,
        height: CGFloat,
        isLandscape: Bool,
        tier: PlayerTokens.PlayerSizeTier
    ) -> some View {
        // r23h：条钉在面板顶，见本函数头注释。
        VStack(spacing: 8) {
            // r28 tone-aware：平台条标题/搜索/选中圈跟专辑取色深场走白字、浅场走墨色。
            // r30：点标题弹来源小菜单（壳版 #hall-src-menu 思路）。
            PlatformStripView(
                viewModel: viewModel,
                isDark: panelTone.isDark,
                onSourceMenuTap: { sourceMenuShown = true }
            )
            // r30 来源内容：每日推荐 = 环/跑马带，其余 5 栏 = rail 列表
            // （原 HomeRailPageView，原样搬进本文件 RailSourceListView）。
            // 来源切换不走翻页手势：菜单点选即切；面板内竖滑归外层
            // ScrollView 滚整页，横滑归环。
            sourceContent(tier: tier)
                .id(viewModel.selectedSource)
                .transition(.opacity)
        }
        .padding(10)
        .frame(width: width, height: height)
        .background(
            LinearGradient(
                colors: [panelTone.a, panelTone.b, panelTone.c],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius22))
        // r30 来源小菜单浮层（壳版 #hall-src-menu 思路：挂在标题下、
        // 可溢出面板边缘；点菜单外任意处关，选来源后关）。
        // overlay 挂在 clipShape 之后，不被圆角裁掉；菜单卡本身是浅色卡、
        // 与面板取色无关，任何 tone 下都可读。
        .overlay(alignment: .topLeading) {
            if sourceMenuShown {
                sourceMenuOverlay
            }
        }
    }

    /// r30 来源内容：一次只显示一个来源。每日推荐走修好的环/跑马带，
    /// 其余 5 栏走 rail 列表（取数见 `HomeViewModel.loadRailPage`，
    /// 首次访问拉取、之后缓存，喜欢栏每次切回都重拉）。
    @ViewBuilder
    private func sourceContent(
        tier: PlayerTokens.PlayerSizeTier
    ) -> some View {
        switch viewModel.selectedSource {
        case .daily:
            dailyRingContent(tier: tier)
        case .featured, .collections, .liked, .created, .radio:
            RailSourceListView(viewModel: viewModel)
        }
    }

    /// r30 来源小菜单浮层：标题下 6 行来源（每日推荐 / 精选 / 用户收藏 /
    /// 喜欢的歌曲 / 用户创建的歌单 / 电台），当前来源打勾；点行切来源并关菜单，
    /// 点菜单外任意处只关菜单。壳版 `#hall-src-menu`（public/index.html
    /// 约 250 行 + hall/option-wheel.js）同款思路：浮层挂在标题下、
    /// 内容由来源列表填、点选切换；原生不用滚轮，用点选列表。
    private var sourceMenuOverlay: some View {
        ZStack(alignment: .topLeading) {
            // 点菜单外关：整块面板大小的透明层（菜单卡在它上面，
            // 卡上的点按走行按钮，不落到这里）。
            Color.black.opacity(0.001)
                .onTapGesture { sourceMenuShown = false }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(HomeRailPage.allCases, id: \.rawValue) { page in
                    Button(action: {
                        withAnimation(.easeOut(duration: 0.18)) {
                            viewModel.selectSource(page)
                        }
                        sourceMenuShown = false
                    }) {
                        HStack(spacing: 8) {
                            Text(page.title(platform: viewModel.selectedPlatform))
                                .font(.liziBody(size: LiziTokens.size16, weight: page == viewModel.selectedSource ? .semibold : .regular))
                                .foregroundColor(LiziTokens.ink)
                                .lineLimit(1)
                            Spacer()
                            if page == viewModel.selectedSource {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(LiziTokens.ink)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("来源：\(page.title(platform: viewModel.selectedPlatform))")
                }
            }
            .frame(width: 208)
            .background(LiziTokens.paper)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
            // 面板内边距 10 + 条 48 + 间距 8 = 66，菜单顶贴在条下。
            .padding(.leading, 10)
            .padding(.top, 66)
        }
    }

    /// 每日推荐环内容（原 dailyPanel 里的环，原样搬过来；
    /// r30 来源切换只换容器，不动环本身；横屏/竖屏两分支原来就是同一份，
    /// 合并成一个——环本身不分横竖屏，横屏只是面板窗更矮、内容裁得更多）。
    /// r21：首页 3D 封面环（平面跑马带常态 + 上滑展开全屏圆环；
    /// 见 HomeCoverRingView 文件头视频逐帧规格）。
    /// 内容是播放队列（非空时）或每日推荐（队列为空时），
    /// 两份都空时不显示。环本身的实现是另一个工人的，
    /// 本轮只动它在面板里的位置，不动 HomeCoverRingView.swift。
    private func dailyRingContent(
        tier: PlayerTokens.PlayerSizeTier
    ) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            HomeCoverRingView(
                model: ringModel,
                dailyTracks: viewModel.daily.map { $0.track },
                isLoadingDaily: viewModel.isLoadingDaily,
                dailyEmptyReason: viewModel.dailyEmptyReason,
                marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                tier: tier,
                panelIsDark: panelTone.isDark
            )
        }
    }

    /// r30：原 `HomeRailPagerView.swift` 里的 `HomeRailPageView`，随翻页器
    /// 文件删除原样搬进本文件、只改名（`railPage` → `selectedSource`），
    /// 行/三态/点按行为一行不改。
    ///
    /// 每日推荐之外的 5 栏（精选 / 用户收藏 / 喜欢的歌曲 / 用户创建的歌单 / 电台）
    /// 在面板里的样子。栏里条目的形状照壳版 `public/app.js` 的 marqCardHtml
    /// （约 12344–12400 行）1:1 抄（只换容器为一次一栏，不搬壳版代码；
    /// 行组件复用 RailDetailView 同款，不另起形状）：
    /// - 曲目行 = 封面 + 歌名 + 歌手·专辑 + 时长（TrackRowView，与 RailDetailView 同款）；
    /// - 歌单/电台卡 = 封面 56 + 名字 + 创建者·数量 + chevron
    ///   （与 RailDetailView 的 playlistCardRow / stationCardRow 同款；
    ///   壳版卡上还有「歌单/电台」小签，副标题已写清数量/创建者，这里不另贴签）；
    /// - 分组说明卡（网易「我创建的歌单 / 我收藏的歌单」、Apple Music
    ///   「官方热门歌单（非本人收藏）」、本地星标说明）= 12pt 小字行，不可点
    ///   （壳版 marq__card--group 同款）。
    /// - 平台返回类型本来就不同（见 RailsBridge 文件头）：网易/QQ/波点精选=歌单、
    ///   酷狗/汽水精选=曲目、酷我精选=排行榜（歌单）；空态文案原样保留
    ///   （如「这一层没有歌曲」「这一层没有歌单」与各平台诚实原因）。
    ///
    /// 面板是定高窗：最多放 3 条可点条目（竖屏内容区约 255pt，行约 68–72pt，
    /// 再加「查看全部」一行正好放下；横屏面板只有约 140 高，栏头 + 条占掉
    /// 大半后 rail 栏只剩约一行的位置、其余裁断是模板原意），其余走底部
    /// 「查看全部」进 RailDetailView 整页。
    /// 点行行为与 RailDetailView 一致：曲目点播（setQueue 整份曲目，含分组卡
    /// 之后的全部曲目）、歌单卡进歌单详情页（.playlist 路由）、电台频道卡
    /// 进电台整页（.rail radio；频道下钻在详情页里点，面板不另做下钻层；
    /// 波点电台本身就是曲目，点行直接播）。
    /// 加载/失败/空态走 RailDetailView 同款三态（文案由 RailsBridge 原样给）。
    /// 取数在 `HomeViewModel.loadRailPage`（切到某栏时再拉该栏、首次拉取后缓存，
    /// 喜欢栏每次切回都重拉——本地星标一点就变，壳版同款不缓存）。
    private struct RailSourceListView: View {
        @ObservedObject var viewModel: HomeViewModel
        @EnvironmentObject private var playback: PlaybackStore
        @EnvironmentObject private var nav: AppNavigation

        /// 面板里最多放几条可点条目（分组说明卡不占名额；见本结构体头注释）。
        private static let maxRows = 3

        private var page: HomeRailPage { viewModel.selectedSource }
        private var platform: String { viewModel.selectedPlatform }

        var body: some View {
            Group {
                if viewModel.isRailPageLoading(page) || viewModel.railResults[page] == nil {
                    loadingView
                } else if let error = viewModel.railResults[page]?.error {
                    errorView(error: error)
                } else if let reason = viewModel.railEmptyReason(for: page) {
                    emptyView(reason: reason)
                } else {
                    entriesView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        // MARK: - 列表层

        private var entriesView: some View {
            let entries = viewModel.railEntries(for: page)
            let tracks = entries.compactMap { entry -> Track? in
                if case .track(let track) = entry { return track }
                return nil
            }
            let shown = visibleEntries(entries)
            let total = entries.filter { entry in
                if case .groupHeader = entry { return false }
                return true
            }.count
            return VStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { entry in
                    entryRow(entry, tracks: tracks)
                }
                if viewModel.isMixedPlaylistsPage(page) {
                    Text("该平台接口不区分自建与收藏，两页显示同一份歌单。")
                        .font(.liziBody(size: LiziTokens.size12))
                        .foregroundColor(LiziTokens.ink3)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
                viewAllButton(total: total)
            }
        }

        /// 面板里放得下的条目（按顺序取最多 maxRows 条可点条目，路过的
        /// 分组说明卡一并带上、不占名额；超出的走「查看全部」）。
        private func visibleEntries(_ entries: [RailEntry]) -> [RailEntry] {
            var out: [RailEntry] = []
            var count = 0
            for entry in entries {
                if case .groupHeader = entry { out.append(entry); continue }
                guard count < Self.maxRows else { break }
                out.append(entry)
                count += 1
            }
            return out
        }

        @ViewBuilder
        private func entryRow(_ entry: RailEntry, tracks: [Track]) -> some View {
            switch entry {
            case .groupHeader(let text):
                Text(text)
                    .font(.liziBody(size: LiziTokens.size12, weight: .semibold))
                    .foregroundColor(LiziTokens.ink3)
                    .padding(.vertical, 4)
            case .track(let track):
                TrackRowView(
                    track: track,
                    isCurrent: playback.currentTrack?.id == track.id
                        && playback.currentTrack?.platform == track.platform,
                    isCompact: true
                ) {
                    playback.setQueue(tracks, startAt: trackIndex(track, in: tracks))
                }
            case .playlist(let playlist):
                Button(action: {
                    nav.show(.playlist(platform: playlist.source, id: playlist.id, isRank: playlist.isRank))
                }) {
                    playlistCardRow(playlist: playlist)
                }
                .buttonStyle(.plain)
            case .station(let station):
                Button(action: { nav.show(.rail(kind: "radio", platform: platform)) }) {
                    stationCardRow(station: station)
                }
                .buttonStyle(.plain)
            }
        }

        @ViewBuilder
        private func viewAllButton(total: Int) -> some View {
            if let kind = page.railKind {
                Button(action: { nav.show(.rail(kind: kind.rawValue, platform: platform)) }) {
                    HStack(spacing: 4) {
                        Text(total > Self.maxRows ? "查看全部（共 \(total) 项）" : "查看全部")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                    .foregroundColor(LiziTokens.ink2)
                }
                .padding(.top, 8)
                .accessibilityLabel("查看全部\(page.title(platform: platform))")
            }
        }

        // MARK: - 卡片行（与 RailDetailView 同款形状，见本结构体头注释）

        private func playlistCardRow(playlist: Playlist) -> some View {
            HStack(spacing: 12) {
                CoverImageView(url: playlist.coverURL, placeholderIconSize: 20)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                        .foregroundColor(LiziTokens.ink)
                        .lineLimit(1)
                    Text(playlistSubtitle(playlist: playlist))
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(LiziTokens.ink3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }

        private func stationCardRow(station: RadioStation) -> some View {
            HStack(spacing: 12) {
                CoverImageView(url: station.coverURL, placeholderIconSize: 20)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name)
                        .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                        .foregroundColor(LiziTokens.ink)
                        .lineLimit(1)
                    Text(stationSubtitle(station: station))
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink3)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(LiziTokens.ink3)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }

        private func playlistSubtitle(playlist: Playlist) -> String {
            var parts: [String] = []
            if !playlist.creator.isEmpty { parts.append(playlist.creator) }
            if playlist.trackCount > 0 { parts.append("\(playlist.trackCount) 首") }
            return parts.joined(separator: " · ")
        }

        private func stationSubtitle(station: RadioStation) -> String {
            var parts: [String] = []
            if !station.creator.isEmpty { parts.append(station.creator) }
            if station.trackCount > 0 { parts.append("\(station.trackCount) 期节目") }
            if station.playCount > 0 { parts.append("播放 \(station.playCount)") }
            return parts.joined(separator: " · ")
        }

        // MARK: - 通用状态（RailDetailView 同款三态，面板内居中）

        private var loadingView: some View {
            HStack(spacing: 8) {
                ProgressView()
                Text("正在拉取\(page.title(platform: platform))…")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }

        private func emptyView(reason: String) -> some View {
            Text(reason)
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(LiziTokens.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 24)
        }

        private func errorView(error: String) -> some View {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundColor(LiziTokens.accent)
                Text(error)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink2)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    viewModel.loadRailPage(page, force: true)
                }
                .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(LiziTokens.ink)
                .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(.horizontal, 24)
        }

        // MARK: - 工具

        private func trackIndex(_ track: Track, in tracks: [Track]) -> Int {
            tracks.firstIndex(where: { $0.id == track.id && $0.platform == track.platform }) ?? 0
        }
    }

    // MARK: - 顶栏

    /// r22j：照抄壳版 `.topbar` + `.brand`（`public/index.html` 约
    /// 109–131 行 + `public/app.css` 约 269–303 行），一行、定高 64、
    /// 左列设置齿轮 38 + 搜索 38（平面按钮、无底色；设置在前、搜索在后，
    /// 与壳版 DOM 顺序一致）、品牌真居中。
    ///
    /// 品牌不是抠图、不是图片资源（用户 04:56 纠正：抠图以后会出新 bug，
    /// 两张抠图已删，不许再用）：LI 标记和 LIZI 四个字母是 SwiftUI Path
    /// 按壳版内联 SVG 坐标照抄画出来的矢量（`BrandMarkView` /
    /// `BrandWordView`，缩放不糊、深浅底都不怕）；kun 是真文字
    /// （Fraunces 斜体 500、11px，包里 r19 已接的字体，直接 Text 打）。
    /// r28：尺寸不再照壳版 CSS（17×17 / 34×15），按用户首页截图实测
    /// 1:1 校准——LI 16.7×11.7、LIZI 33.3×10.7、kun 宽 18.3、
    /// 间距 LI→LIZI 9.3、LIZI→kun 9.7（截图 1206×2622 @3x，÷3 为 pt）；
    /// 整体仍居中，纵向位置不动。旧 gap 9（壳版 `.brand` gap 9px）
    /// 已被 r28 的 9.3 / 9.7 取代，见 `topBar` 内 HStack 处。
    ///
    /// 居中做法：HStack（左列按钮 + Spacer）+ `.overlay(alignment:
    /// .center)` 放品牌——overlay 以整行全宽为基准居中，品牌不随左列
    /// 宽度偏左或偏右；不用 ZStack（尺寸歧义，r22j 旧版已换掉）。
    ///
    /// 按钮画完整（用户 05:08「设置和搜索按钮要画完整」）：r28 起齿轮字形 18、
    /// 搜索字形 16（壳版 1:1；旧模板量 30/28 已作废；38pt 框、
    /// 不加 `.clipped()`，SF Symbol 全尺寸渲染，不裁切）。
    ///
    /// 纵向位置（用户 04:59：「放在中间灵动岛下面一点点」）：整行不按
    /// 安全区顶往下排，`.ignoresSafeArea(edges: [.top, .bottom])` 后
    /// `topPad` 是行顶到屏顶的距离——竖屏 31pt，品牌纵向中心 =
    /// 31 + 64/2 = 63pt（用户 04:51 截图量：品牌框 x 157–244pt、
    /// y 55–71pt，横向中心 200.5pt ≈ 屏宽一半 201pt，纵向中心约 63pt；
    /// 灵动岛底约 48pt，品牌顶边离岛底约 7pt，就是「下面一点点」）；
    /// 横屏顶上没有灵动岛，topPad = 0，品牌中心 = 32pt。按钮 38pt
    /// 触摸区与品牌同行居中。
    /// 横屏 `leadingPad` = leading 安全区 + 16（灵动岛在侧边，按钮要让
    /// 开屏幕圆角，不被裁掉；竖屏就是 16）。
    private func topBar(topPad: CGFloat, leadingPad: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button(action: { nav.show(.settings) }) {
                Image(systemName: "gearshape")
                    // r28：按壳版 1:1 缩小——`.tbtn--icon .ico` 18×18
                    //（app.css:330–331），触摸框 38×38 不动；字重 medium
                    //（壳版 `.ico` stroke-width 1.9，app.css:66，medium
                    // 约 1.8pt，比 semibold 更接近，见 r28 交回）。
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("设置")
            Button(action: { nav.show(.search) }) {
                Image(systemName: "magnifyingglass")
                    // r28：按壳版 1:1 缩小——`.search .ico` 16×16
                    //（app.css:216），触摸框 38×38 不动；字重 medium
                    //（同上，壳版 stroke-width 1.9）。
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("搜索")
            Spacer()
        }
        .padding(.leading, leadingPad)
        .padding(.trailing, 16)
        .frame(height: 64)
        .overlay(alignment: .center) {
            // r28：间距按用户截图实测（1206×2622 @3x，÷3 为 pt）——
            // LI→LIZI 28px = 9.3pt；LIZI→kun 29px = 9.7pt，
            // 用 spacing 9.3 + kun 前 0.4pt 补齐（HStack 只有一个
            // spacing，两段不等距只能这样分）。
            HStack(alignment: .center, spacing: 9.3) {
                BrandMarkView()
                BrandWordView()
                Text("kun")
                    .font(.custom("Fraunces", size: 11).italic().weight(.medium))
                    // r28：字号仍 11pt（k 高 8.1pt ≈ 图里 7.7pt，见下）；
                    // tracking 0.22 → 1.1——图里 kun 宽 55px = 18.3pt，
                    // 11pt Fraunces 斜体实测墨宽仅 ~16.3pt（见 r28 交回），
                    // 字号加大到 12pt 会把 k 高顶到 8.7pt（超图 1.0pt），
                    // 只能靠字距补宽：tracking 1.1 时墨宽 18.1～18.7pt。
                    .tracking(1.1)
                    .foregroundColor(LiziTokens.ink2)
                    .padding(.leading, 0.4) // 补到 LIZI→kun 间距 9.7pt
                    // r28：删 `.offset(y: 2)`——旧 2pt 是按 15pt 高的
                    // LIZI 配的；LIZI 改 10.7pt 后，kun 不偏移时 k 顶
                    // 正在 LIZI 顶下 1.2pt（图里 4px = 1.3pt），
                    // 再 +2 就掉到 3.2pt，错 1.9pt。
            }
        }
        .padding(.top, topPad) // 品牌纵向中心 = topPad + 32（屏顶起算，见上）
    }
}

/// r24 分界手柄（只画样子，手势挂在 HomeView 里 overlay 处）：
/// 28pt 高的透明触摸区（`.contentShape(Rectangle())` 保证整块都吃触摸，
/// Color.clear 本身不画东西）+ 中间一条 49×5 圆角胶囊（低对比度墨色，
/// r28：视频实测宽约 90px ≈ 49pt）。
/// 不加任何缩放手势、不加 scaleEffect——只改两块高度分配。
private struct HomeResizeHandle: View {
    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 2)
                .fill(LiziTokens.ink.opacity(0.28))
                .frame(width: 49, height: 5)
        }
        .contentShape(Rectangle())
    }
}

/// 品牌 LI 标记：SwiftUI Path 按壳版 `public/index.html` 内联 SVG 照抄
/// （`viewBox="328 329 368 366"`，4 个 polygon，坐标一个数都不改；
/// 只是先平移 viewBox 原点、再缩放——Path 里的数字就是壳版原数）。
/// r28：缩放不再是等比 17pt——用户截图实测标记 50×35px = 16.7×11.7pt
/// （宽高比 1.43:1，不是壳版 SVG 的近正方形），按图横向缩 16.7/368、
/// 纵向缩 11.7/366，框 16.7×11.7；几何底本仍是
/// `public/forms-labs/assets/logo.svg`（已核对，4 个 polygon 与此处
/// 逐点一致，就是同一枚标记）。
/// 不是图片资源，不是抠图；填墨色（壳版 `.brand__mark` fill currentColor，
/// 浅色顶栏上就是墨色）。
private struct BrandMarkView: View {
    var body: some View {
        Path { path in
            // polygon 1
            path.move(to: CGPoint(x: 328.94, y: 329.76))
            path.addLine(to: CGPoint(x: 396.71, y: 329.76))
            path.addLine(to: CGPoint(x: 396.71, y: 569.57))
            path.addLine(to: CGPoint(x: 458.02, y: 519.41))
            path.addLine(to: CGPoint(x: 458.02, y: 545.48))
            path.addLine(to: CGPoint(x: 328.94, y: 649.91))
            path.closeSubpath()
            // polygon 2
            path.move(to: CGPoint(x: 328.94, y: 672.81))
            path.addLine(to: CGPoint(x: 396.71, y: 617.97))
            path.addLine(to: CGPoint(x: 396.71, y: 630.67))
            path.addLine(to: CGPoint(x: 554.47, y: 630.67))
            path.addLine(to: CGPoint(x: 587.80, y: 694.32))
            path.addLine(to: CGPoint(x: 328.94, y: 694.32))
            path.closeSubpath()
            // polygon 3
            path.move(to: CGPoint(x: 627.86, y: 329.76))
            path.addLine(to: CGPoint(x: 695.15, y: 329.76))
            path.addLine(to: CGPoint(x: 695.15, y: 372.74))
            path.addLine(to: CGPoint(x: 627.86, y: 428.80))
            path.closeSubpath()
            // polygon 4
            path.move(to: CGPoint(x: 490.18, y: 566.83))
            path.addLine(to: CGPoint(x: 695.15, y: 395.57))
            path.addLine(to: CGPoint(x: 695.15, y: 694.32))
            path.addLine(to: CGPoint(x: 627.86, y: 694.32))
            path.addLine(to: CGPoint(x: 627.86, y: 479.80))
            path.addLine(to: CGPoint(x: 490.18, y: 595.37))
            path.closeSubpath()
        }
        // r26 修：顺序必须是「先平移 viewBox 原点、再缩放」。旧写法
        // `CGAffineTransform(translationX: -328, y: -329).scaledBy(...)`
        // 是 scaledBy 拼在平移之后，点先被缩放（~0.046×）再平移 -328，
        // 标记落在约 (-313,-314)，屏外看不见。现用 scale.concatenating(translate)：
        // 点先平移 (-328,-329)、再缩放。r28 再核：缩放改非等比
        // （16.7/368 × 11.7/366）后，墨迹落在 x 0.04…16.66、
        // y 0.02…11.68 的框内，仍在 16.7×11.7 框里，不出屏。
        .transform(CGAffineTransform(scaleX: 16.7 / 368, y: 11.7 / 366)
            .concatenating(CGAffineTransform(translationX: -328, y: -329)))
        .fill(LiziTokens.ink)
        .frame(width: 16.7, height: 11.7)
    }
}

/// 品牌 LIZI 四个字母：SwiftUI Path 按壳版 `public/index.html` 内联 SVG
/// 照抄（`viewBox="0 0 224 100"`；L = polygon，I = rect，
/// Z = rect + polygon + rect，I = rect）。
/// r28：按用户截图实测 100×32px = 33.3×10.7pt 校准（壳版是 34×15，
/// 纵向压到约 0.71×）。只等比缩会让字母间距剩 2.7pt（图里 3.3pt），
/// 所以字母 x 坐标各右移——I +3、Z 组 +6、末 I +9（总宽 224→233
/// 单位，间距 18→21 单位），再非等比缩到 33.3×10.7；字形本身
/// （L 斜切脚、Z 斜笔）一个点都没改，只是整体平移。
/// 不是字体打出来的（壳版本来就不是字体，是多边形），不是图片资源。
private struct BrandWordView: View {
    var body: some View {
        Path { path in
            // L：polygon (0,0 19,0 19,81 47,81 66,100 0,100)——r28 未动
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 19, y: 0))
            path.addLine(to: CGPoint(x: 19, y: 81))
            path.addLine(to: CGPoint(x: 47, y: 81))
            path.addLine(to: CGPoint(x: 66, y: 100))
            path.addLine(to: CGPoint(x: 0, y: 100))
            path.closeSubpath()
            // I：rect x87 y0 w19 h100（r28：壳版 x84，+3 拉开字母间距）
            path.addRect(CGRect(x: 87, y: 0, width: 19, height: 100))
            // Z：rect(127,0,66,18) + polygon(175,18 193,18 145,82 127,82)
            //    + rect(127,82,66,18)（r28：壳版 x121，+6）
            path.addRect(CGRect(x: 127, y: 0, width: 66, height: 18))
            path.move(to: CGPoint(x: 175, y: 18))
            path.addLine(to: CGPoint(x: 193, y: 18))
            path.addLine(to: CGPoint(x: 145, y: 82))
            path.addLine(to: CGPoint(x: 127, y: 82))
            path.closeSubpath()
            path.addRect(CGRect(x: 127, y: 82, width: 66, height: 18))
            // I：rect x214 y0 w19 h100（r28：壳版 x205，+9）
            path.addRect(CGRect(x: 214, y: 0, width: 19, height: 100))
        }
        // r28：非等比缩到截图实测 33.3×10.7（总宽 233 单位：33.3/233；
        // 高 100 单位：10.7/100）。字母实测：L/Z 9.43、I 2.72、
        // 间距 3.00，相对图里 9.7 / 2.7 / 3.3 误差 ≤0.30pt。
        .transform(CGAffineTransform(scaleX: 33.3 / 233, y: 10.7 / 100))
        .fill(LiziTokens.ink)
        .frame(width: 33.3, height: 10.7)
    }
}

// MARK: - 专辑取色（r28）

/// 面板 tone：壳版 `--tone-a/b/c`（`public/m/m.js` applyTone 取色板
/// stops[2]/[3]/[4]）+ 深/浅场。深场白字、浅场墨字（壳版 pickInk 同款）。
struct AlbumTone {
    let a: Color
    let b: Color
    let c: Color
    let isDark: Bool

    var text: Color { isDark ? .white : LiziTokens.ink }
    var secondaryText: Color { isDark ? .white.opacity(0.62) : LiziTokens.ink3 }

    /// 默认色（壳版 pages.css 里 --tone-a/b/c 清掉后的回落值；
    /// 深场，白字）。
    static let fallback = AlbumTone(
        a: Color(hex: 0x5B5BD6),
        b: Color(hex: 0xB04F8C),
        c: Color(hex: 0x2F6F8F),
        isDark: true
    )
}

/// 封面取色：照搬壳版 `public/player.js` 的「OKLCH 聚类 k=4」
/// （2026-11-08 起全站统一算法，与 color-lab.html 的 C 算法逐行一致）：
/// 1. 32×32 采样，丢掉低透明度（alpha < 200）和纯白高光
///    （(max+min)/2 > 246）；
/// 2. 有效像素转真实 OKLCH；3. k=4，初始中心按明度四分位给，最多迭代
///    10 次；4. 4 个中心按明度排好，沿折线均匀取 5 档；
/// 5. 墨色按中间三档的平均相对亮度选深/浅场（< 0.30 深场）。
/// 只要 stops + field（面板只要 tone-a/b/c 与深浅场；main/accent/
/// colors 接口不在这里复刻）。
/// 全空（透明/纯白）也给可用 5 档（平均色 [96,116,190] 作种子），
/// 绝不返回空色板；只有图片本身解不出来才返回 nil（调用方回默认色）。
enum AlbumToneExtractor {
    /// 取 5 档色板 + 深浅场；图片解不出来返回 nil（调用方回默认色）。
    static func tone(from image: UIImage) -> AlbumTone? {
        guard let pixels = sample32(image) else { return nil }
        let stops = paletteStops(pixels: pixels)
        return AlbumTone(
            a: color(stops[2]),
            b: color(stops[3]),
            c: color(stops[4]),
            isDark: fieldIsDark(stops: stops)
        )
    }

    // MARK: 采样（32×32，壳版 COLOR_SIDE=32）

    private struct Pixel { var r: Double; var g: Double; var b: Double; var a: Double }

    private static func sample32(_ image: UIImage) -> [Pixel]? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 32
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(
            data: &bytes,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        var out: [Pixel] = []
        out.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            out.append(Pixel(
                r: Double(bytes[i * 4]),
                g: Double(bytes[i * 4 + 1]),
                b: Double(bytes[i * 4 + 2]),
                a: Double(bytes[i * 4 + 3])
            ))
        }
        return out
    }

    // MARK: OKLCH（壳版 rgbToOklch / oklchToRgbRaw / oklchToHex 原样照搬）

    private struct Oklch { var l: Double; var c: Double; var h: Double }

    private static func srgbToLin(_ v: Double) -> Double {
        let c = v / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private static func normHue(_ h: Double) -> Double {
        let v = h.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }

    private static func hueDelta(_ a: Double, _ b: Double) -> Double {
        (a - b + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private static func rgbToOklch(r: Double, g: Double, b: Double) -> Oklch {
        let rl = srgbToLin(r)
        let gl = srgbToLin(g)
        let bl = srgbToLin(b)
        let l = 0.4122214708 * rl + 0.5363325363 * gl + 0.0514459929 * bl
        let m = 0.2119034982 * rl + 0.6806995451 * gl + 0.1073969566 * bl
        let s = 0.0883024619 * rl + 0.2817188376 * gl + 0.6299787005 * bl
        let l_ = cbrt(l)
        let m_ = cbrt(m)
        let s_ = cbrt(s)
        let L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        let C = sqrt(A * A + B * B)
        let H = C > 1e-7 ? normHue(atan2(B, A) * 180 / Double.pi) : 0
        return Oklch(l: L, c: C, h: H)
    }

    private static func oklchToRgbRaw(_ o: Oklch) -> (r: Double, g: Double, b: Double) {
        let hr = o.h * Double.pi / 180
        let A = o.c * cos(hr)
        let B = o.c * sin(hr)
        let l_ = o.l + 0.3963377774 * A + 0.2158037573 * B
        let m_ = o.l - 0.1055613458 * A - 0.0638541728 * B
        let s_ = o.l - 0.0894841775 * A - 1.2914855480 * B
        let l = l_ * l_ * l_
        let m = m_ * m_ * m_
        let s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return (linToSrgb(r), linToSrgb(g), linToSrgb(b))
    }

    private static func inGamut(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
        rgb.r >= -0.0006 && rgb.r <= 1.0006 &&
        rgb.g >= -0.0006 && rgb.g <= 1.0006 &&
        rgb.b >= -0.0006 && rgb.b <= 1.0006
    }

    /// OKLCH → 0–255 RGB 三元组；超出色域只降彩度（二分 16 次），不粗暴截断。
    private static func oklchToRGB(_ o: Oklch) -> (r: Int, g: Int, b: Int) {
        let L = min(max(o.l, 0), 1)
        let H = normHue(o.h)
        var c = max(o.c, 0)
        if !inGamut(oklchToRgbRaw(Oklch(l: L, c: c, h: H))) {
            var lo = 0.0
            var hi = c
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                if inGamut(oklchToRgbRaw(Oklch(l: L, c: mid, h: H))) { lo = mid } else { hi = mid }
            }
            c = lo
        }
        let rgb = oklchToRgbRaw(Oklch(l: L, c: c, h: H))
        return (
            r: Int((min(max(rgb.r, 0), 1) * 255).rounded()),
            g: Int((min(max(rgb.g, 0), 1) * 255).rounded()),
            b: Int((min(max(rgb.b, 0), 1) * 255).rounded())
        )
    }

    private static func relLum(_ rgb: (r: Int, g: Int, b: Int)) -> Double {
        0.2126 * srgbToLin(Double(rgb.r)) +
        0.7152 * srgbToLin(Double(rgb.g)) +
        0.0722 * srgbToLin(Double(rgb.b))
    }

    /// 深/浅场：中间三档（stops[1..3]）平均相对亮度 < 0.30 → 深场（壳版 pickInk）。
    private static func fieldIsDark(stops: [(r: Int, g: Int, b: Int)]) -> Bool {
        (relLum(stops[1]) + relLum(stops[2]) + relLum(stops[3])) / 3 < 0.30
    }

    private static func color(_ rgb: (r: Int, g: Int, b: Int)) -> Color {
        Color(red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    // MARK: 聚类（壳版 oklchDist / centroidOf / rampFromCenters / paletteFromData）

    /// OKLCH 距离：明度 + 彩度 + 加权色相差。
    private static func oklchDist(_ a: Oklch, _ b: Oklch) -> Double {
        let dL = a.l - b.l
        let dC = a.c - b.c
        let dh = hueDelta(a.h, b.h) * Double.pi / 180
        let dH = 2 * sqrt(max(a.c, 0) * max(b.c, 0)) * sin(dh / 2)
        return dL * dL + dC * dC + dH * dH
    }

    /// 簇中心：L/C 算术平均，色相按彩度加权走圆周平均。
    private static func centroidOf(_ points: [Oklch]) -> Oklch {
        guard !points.isEmpty else { return Oklch(l: 0.5, c: 0, h: 0) }
        var L = 0.0
        var C = 0.0
        var sinSum = 0.0
        var cosSum = 0.0
        for p in points {
            L += p.l
            C += p.c
            let w = max(p.c, 0.0001)
            sinSum += sin(p.h * Double.pi / 180) * w
            cosSum += cos(p.h * Double.pi / 180) * w
        }
        let n = Double(points.count)
        return Oklch(
            l: L / n,
            c: C / n,
            h: C > 1e-6 ? normHue(atan2(sinSum, cosSum) * 180 / Double.pi) : 0
        )
    }

    /// 4 个中心按明度排好后，沿折线均匀取 5 档。
    private static func rampFromCenters(_ centers: [Oklch], count: Int = 5) -> [Oklch] {
        let cs = centers.sorted { $0.l < $1.l }
        guard !cs.isEmpty else {
            return (0..<count).map { i in
                Oklch(l: 0.2 + Double(i) * 0.17, c: 0.08, h: 0)
            }
        }
        if cs.count == 1 {
            let c = cs[0]
            return (0..<count).map { i in
                let t = Double(i) / Double(count - 1)
                return Oklch(
                    l: min(max(c.l + (t - 0.5) * 0.34, 0.03), 0.97),
                    c: c.c * (0.55 + 0.45 * sin(Double.pi * t)),
                    h: c.h
                )
            }
        }
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let pos = t * Double(cs.count - 1)
            let seg = min(cs.count - 2, Int(pos.rounded(.down)))
            let f = pos - Double(seg)
            let a = cs[seg]
            let b = cs[seg + 1]
            return Oklch(
                l: a.l + (b.l - a.l) * f,
                c: a.c + (b.c - a.c) * f,
                h: normHue(a.h + hueDelta(b.h, a.h) * f)
            )
        }
    }

    /// 像素 → 5 档 RGB（壳版 paletteFromData；只取 stops，不取 main/accent）。
    private static func paletteStops(pixels: [Pixel]) -> [(r: Int, g: Int, b: Int)] {
        var pts: [Oklch] = []
        var ar = 0.0
        var ag = 0.0
        var ab = 0.0
        var an = 0.0
        for p in pixels {
            if p.a < 200 { continue }
            let mx = max(p.r, p.g, p.b)
            let mn = min(p.r, p.g, p.b)
            if (mx + mn) / 2 > 246 { continue }  // 纯白高光没有色彩信息
            ar += p.r
            ag += p.g
            ab += p.b
            an += 1
            pts.append(rgbToOklch(r: p.r, g: p.g, b: p.b))
        }
        // 全空（透明 / 纯白）也必须给出可用的 5 档（壳版同款种子色）。
        let avg = an > 0
            ? (r: ar / an, g: ag / an, b: ab / an)
            : (r: 96.0, g: 116.0, b: 190.0)
        if pts.isEmpty {
            return rampFromCenters([rgbToOklch(r: avg.r, g: avg.g, b: avg.b)])
                .map { oklchToRGB($0) }
        }
        let k = 4
        let sorted = pts.sorted { $0.l < $1.l }
        var centers: [Oklch] = []
        for i in 0..<k {
            let start = (i * sorted.count) / k
            let end = ((i + 1) * sorted.count) / k
            centers.append(centroidOf(Array(sorted[start..<max(start + 1, end)])))
        }
        var groups: [[Oklch]] = []
        var assigns: [Int] = []
        for _ in 0..<10 {
            groups = Array(repeating: [], count: k)
            var nextAssign: [Int] = []
            var changed = false
            for (i, p) in pts.enumerated() {
                var best = 0
                var bestD = Double.infinity
                for j in 0..<k {
                    let d = oklchDist(p, centers[j])
                    if d < bestD { bestD = d; best = j }
                }
                nextAssign.append(best)
                if i >= assigns.count || assigns[i] != best { changed = true }
                groups[best].append(p)
            }
            assigns = nextAssign
            centers = groups.enumerated().map { j, g in
                g.isEmpty ? centers[j] : centroidOf(g)
            }
            if !changed { break }
        }
        return rampFromCenters(centers).map { oklchToRGB($0) }
    }
}
