import SwiftUI

/// 首页（大厅）：顶栏 + Hero 大卡 + 铺色面板（平台条 + 来源 chips + 跑马带/环）+ rails + 本地音乐。
///
/// r24 首页两卡拖动改尺寸：Hero 底边 / 面板顶边接缝处一条 28pt 高分界手柄
/// （上下各压 14pt，中间一条 36×4 圆角胶囊），竖直拖动改两块高度分配，
/// 松手停在哪就是哪（不回弹、不吸附、不贴靠档位）；Hero 与面板高度之和
/// 恒等于 contentH，首屏仍拼满。尺寸按方向分别持久化，见下面
/// heroFractionPortraitKey / heroFractionLandscapeKey（竖屏默认 0.5、
/// 横屏默认 9/16）；拖动中只改 @State、不写 UserDefaults，松手才写当前
/// 方向的 key。上下限见 body 里 minHeroH / minPanelH 的注释（数都从
/// HeroCardView / PlatformStripView / SourceChipsView / HomeCoverRingView
/// 的代码量出来，不是拍脑袋）。拖动时外层 ScrollView 用
/// `.scrollDisabled(dragging)` 停滚；手柄 28pt 高只盖住 Hero 底边 14pt
/// 与面板顶边 14pt——Hero 播放钮底边在 Hero 底边之上 20pt、平台条从面板
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
/// 2. 首屏两块拼满（模板 v2）：竖屏 Hero 上半 + 面板下半，各占一半
///    （402×874 档：顶栏区 95 + 间距 15 + Hero 382 + 面板 382 = 874，
///    面板底边就是屏底边）；横屏 Hero 横幅 + 面板上下叠
///    （932×430 档：顶栏 64 + 间距 26 + Hero 180 + 间距 20 + 面板 140 = 430）。
///    Hero 高由模板公式算（竖屏 (屏高−110)/2，横屏 (屏高−110)×9/16），
///    面板取剩下那份（竖屏一半，横屏 (屏高−110)×7/16）。
///    面板内容（条 42 + chips 52 + 环带 273/291）比面板高，面板是定高窗、
///    只有环在里面竖滑（r23h：条 + 竖屏 chips 钉在面板顶，不进 ScrollView，
///    放歌后 / 手指竖滑都顶不走它们；横屏只钉条，chips 仍在环下竖滑区）。
///    横屏面板矮，里面顺序是条 → 环 → chips（先让封面露出来，chips 在
///    下面滑下去才见），竖屏是条 → chips → 环。
/// 3. 首屏之外（下滑才看到，本地音乐一个像素都不许露首屏）：rails 行，
///    再下面是本地音乐区（文件夹卡片 + 导入按钮，见 LocalMusicView.swift）。
///    段间距 24；底部留白 50（16 净空 + 34 Home Indicator，底部安全区已忽略）。
/// 4. 铺色面板（壳版 `#hall-plat`，圆角 22，内边距 10）：
///    平台条（模板 v2：左列当前来源标题 24pt 粗体 + 7 图标 22pt 间距 5，
///    高 42，右端搜索）→ 来源 chips（P1 stand-in，壳版是悬停来源滚轮，
///    P3 才换；5 个来源一排 pills，点哪个切哪个；长按上下滑切换已在 r23
///    删掉——它和 ScrollView、3D 带子的 UIKit pan 抢触摸会卡死，见
///    SourceRailView.swift 文件头）
///    → 3D 封面环（HomeCoverRingView，平面跑马带常态；环的位置在面板里、
///    面板底色是当前平台品牌色 10% 淡 tint（壳版是平台色 Grainient 满铺；
///    原生浅色卡片 + 墨字要留着，只能淡 tint 近似，不做满铺深色）。
///    壳版面板 min-height 298 = bar 42 + gap 8 + marq 228 + 内边距 20；
///    原生面板内容要再加 chips 一行（chip 32 + 间距 6 + 提示 14 = 52）
///    与视频尺寸环卡（平面带高 card+49，标准档 251，比壳版 marq 228 高 23，
///    另加提示行 6+16），标准档内容约 403，比模板竖屏面板 382 高 21、
///    比横屏面板 140 高得多——差额由面板内竖滑消化，不硬凑。
/// 5. 内容区：非每日来源 = rail 行（P2：标题 + 横向卡片 + 点开展开）。
///    壳版里 rail 内容就是跑马带本身（切来源换带内内容）；原生 P2 把
///    rail 行放在面板下方，是已定结构，本轮只保顺序（面板 → rail 行），
///    不把 rail 行并进跑马带（那要动 ViewModel 逻辑，别的工人）。
/// 6. 本地音乐区在最末（模板 v2）：文件夹卡片（点开是文件列表，点文件播放）
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
    /// 登录提示（r23 集成）：rail 展开需要登录时弹提示，不进详情。
    @State private var loginPrompt: LoginPrompt?
    @State private var loginTarget: LoginSheetTarget?

    // MARK: - r24 首页两卡拖动改尺寸（分界手柄 + 持久化）

    /// 持久化 key（r24，就这两个，不另起）：竖屏 / 横屏各记各的 fraction。
    private static let heroFractionPortraitKey = "lizi.native.home.heroFraction.portrait"
    private static let heroFractionLandscapeKey = "lizi.native.home.heroFraction.landscape"

    /// 读存值：读不到（double(forKey:) 缺键回 0）或非法（非有限、≤0、≥1）
    /// 回落默认——竖屏 0.5、横屏 9/16（0.5625，与 r23 前的模板公式同值）。
    /// 读出后在 body 里再按当前 contentH 与上下限夹一次（见 minFrac / maxFrac）。
    private static func loadHeroFraction(landscape: Bool) -> CGFloat {
        let fallback: CGFloat = landscape ? 9.0 / 16.0 : 0.5
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

    var body: some View {
        GeometryReader { outer in
            // r20 顶栏修复：topBar 原来是 ScrollView 里的第一行，往下滚就滚出
            // 屏幕——QQ 每日推荐有真内容可翻，用户一翻搜索/设置就不见了；
            // 其它平台每日为空、没东西可翻，所以显得只有 QQ 出问题。
            // 根因与平台切换逻辑无关（selectPlatform 对 7 家同一套），所以
            // 不修 ViewModel、不加平台分支：只把 topBar 固定在滚动区之外，
            // 7 个平台同一套固定顶栏。
            // 模板 v2 几何（屏顶坐标；上下安全区都已忽略，outer.size = 整屏）：
            // 竖屏：顶栏区 31+64=95，间距 15，Hero 与面板各占一半
            // （(874−110)/2 = 382），面板底边就是屏底边；横屏：顶栏 64，
            // 间距 26，Hero 横幅 (430−110)×9/16 = 180，间距 20，
            // 面板 (430−110)×7/16 = 140，底边同样是屏底边。
            // 两块左右各留 16pt 边（模板量）；横屏顶栏左列按 leading 安全区
            // 往里收（见 topBar），Hero/面板本身不收（它们的顶在 90pt 以下，
            // 碰不到屏幕圆角）。
            let isLandscape = outer.size.width > outer.size.height
            let topPad: CGFloat = isLandscape ? 0 : 31
            let topBarH: CGFloat = 64
            let gapTop: CGFloat = isLandscape ? 26 : 15
            let gapMid: CGFloat = isLandscape ? 20 : 0
            let contentH = outer.size.height - topPad - topBarH - gapTop - gapMid
            // r24 两卡高度分配：heroH = contentH × fraction（按方向取各自的
            // @State），panelH = contentH − heroH，总高不变、首屏仍拼满。
            // tier 在这里算一次，minPanelH 与 dailyPanel 共用。
            let tier = PlayerTokens.sizeTier(for: outer.size, topInset: outer.safeAreaInsets.top)
            // r24 上下限（数都从代码量出来，见各行注释；fraction 的合法夹取
            // 区间就是 [minHeroH, maxHeroH] 换算成的比例）：
            // - minHeroH：Hero 内上下内边距 20+20（HeroCardView
            //   `.padding(.vertical, 20)`）+ 顶行 30（锁钮 30×30 圆钮，
            //   徽章 12pt 字行高约 15，取大者 30；无歌时顶行是空的，
            //   按有歌的最坏情况算）+ 底行：歌名行高 ≈ titleSize×1.25
            //   （PlayerTokens 文件头同款行高约定）+ 间距 8
            //   （底行 VStack spacing 8）+ 副标题行高 ≈ 13×1.3 ≈ 17
            //   （播放钮 ⌀52 小于底行高，不计）；顶行与底行之间的 Spacer
            //   可压到 0，不计。竖屏 titleSize 42：40+30+52.5+8+17 = 147.5→148；
            //   横屏 titleSize 46：40+30+57.5+8+17 = 152.5→153。
            //   封面是铺满的底图、无固定高，不占下限。
            let titleSize: CGFloat = isLandscape ? 46 : 42
            // r24 构建修（run 44646659508）：原来 `ceil(40 + 30 + titleSize * 1.25 + 8 + 17)`
            // 一整串混着 Int 字面量 + Double 字面量 1.25，编译器报
            // "unable to type-check this expression in reasonable time"。
            // 拆成两步、每步只有一个 CGFloat 锚点，字面量跟着它推断。
            let titleLineH: CGFloat = titleSize * 1.25
            let minHeroH: CGFloat = ceil(40 + 30 + titleLineH + 8 + 17)
            // - 平面带一排封面卡宽（HomeCoverRingView 分档表：compact 188 /
            //   standard 202 / large 220，≈0.51vw），minPanelH 按 tier 走。
    /// r24 构建修（run 44656645107）：`let flatCard` + `switch` 语句在
    /// GeometryReader 的 @ViewBuilder 闭包里，分支产出 `()` 不符合 View，
    /// 编译器报 "type '()' cannot conform to 'View'"。改成三元表达式
    /// （同理下面 minPanelH 的 if/else 也改成三元，免得修完一个又冒一个）。
    let flatCard: CGFloat = tier == .compact ? 188 : tier == .standard ? 202 : 220
            // - minPanelH：面板内边距上下 10+10（dailyPanel `.padding(10)`）
            //   + 平台条 42（PlatformStripView `.frame(height: 42)`）
            //   + 面板 VStack 间距 8（条与下一行之间）。
            //   竖屏再加 chips 行 32（SourceChipsView：13pt 字行高约 16 +
            //   上下内边距 8+8；文件头旧账「chip 32」同值）+ 间距 8
            //   + 至少一排环封面 flatCard（歌名/歌手行与「展开 3D 环」提示行
            //   都在面板内竖滑区里，面板是定高窗、裁断是模板原意，不计入下限；
            //   标准档：20+42+8+32+8+202 = 312）。
            //   横屏面板默认只有约 140 高、chips 在环下面滑下去才见（见 dailyPanel
            //   注释），不计 chips；只要求条之外再露约 1/4 张封面
            //   （flatCard/4，标准档 202/4 ≈ 50，封面露一角、能认出是封面带；
            //   模板默认露 70，标准档下限 20+42+8+50.5 = 120.5→121 < 140，
            //   默认值仍在合法区间里）。
            // r24 构建修：同上，if/else 赋值改三元表达式。
            let ringPeek: CGFloat = flatCard / 4
            let minPanelH: CGFloat = isLandscape
                ? ceil(20 + 42 + 8 + ringPeek)
                : 20 + 42 + 8 + 32 + 8 + flatCard
            // - maxHeroH = contentH − minPanelH。内容极矮时（横屏小屏，
            //   如 667×375 档 contentH 265 < minHeroH 153 + minPanelH 125，
            //   667 宽走 large 档 flatCard 220，下限和是 278）
            //   两条下限打架：保 Hero 下限（歌名 + 播放钮必须完整），面板取
            //   剩下的（仍有条 + 一角封面），不让区间倒挂。
            let maxHeroH = max(minHeroH, contentH - minPanelH)
            let minFrac = minHeroH / contentH
            let maxFrac = maxHeroH / contentH
            let storedFrac = isLandscape ? heroFractionLandscape : heroFractionPortrait
            let fraction = min(max(storedFrac, minFrac), maxFrac)
            let heroH = contentH * fraction
            let panelH = contentH - heroH
            let blockW = outer.size.width - 32
            VStack(spacing: 0) {
                topBar(topPad: topPad, leadingPad: isLandscape ? outer.safeAreaInsets.leading + 16 : 16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 首屏两块拼满（模板 v2）：Hero + 面板，两块高度之和
                        // 加顶栏区与间距，正好等于 ScrollView 框高——首屏一
                        // 个像素都不多不少，本地音乐一个像素都不露（见驱动 10）。
                        VStack(alignment: .leading, spacing: gapMid) {
                            HeroCardView(
                                width: blockW,
                                viewHeight: outer.size.height,
                                height: heroH,
                                titleSize: titleSize,
                                viewModel: viewModel
                            )
                            .padding(.horizontal, 16)

                            // 铺色面板（壳版 `#hall-plat`）：平台条 → 来源 chips →
                            // 跑马带/环，同一块圆角面板里，顺序与壳版 bar → marquee 一致。
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
                        // gapMid = 0 就是接缝本身；横屏 gapMid = 20，手柄
                        // 居中压在 20pt 间隙正中、上下各探进 Hero / 面板 4pt）。
                        // 触摸区 28pt 高（上下各一半）、宽 blockW，与两块同宽；
                        // 中间只画一条 36×4 圆角胶囊（低对比度）。
                        // 透传：手柄上下各 14pt 盖住的区域没有可点控件——Hero
                        // 播放钮底边在 Hero 底边之上 20pt（52 圆钮 + 底内边距
                        // 20，见 HeroCardView），面板顶 14pt 内只有面板内边距
                        // 10 + 平台条顶 4pt（条从面板内 10pt 才起，图标 22 与
                        // 搜索钮 32 居中在条里、更往下，见 PlatformStripView）；
                        // 点按因 DragGesture(minimumDistance: 6) 未触发而失败
                        // 透传，Hero 整卡点按与平台条点按不受影响。
                        // 横向为主的拖动不改尺寸（Hero 左右滑切歌只在接缝上下
                        // 14pt 的窄条里会被手柄先接到，见交回说明）。
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

                        // 首屏之下（下滑才看到）：rails 行 + 本地音乐区。
                        // 本地音乐排在最末；段间距 24 与上面同档。
                        VStack(alignment: .leading, spacing: 24) {
                            if let kind = viewModel.selectedSource.railKind {
                                // P2：四条 rails 各一行（标题 + 横向卡片 + 点开展开）。
                                // 点卡片按类型直达（r24 第 1 件）：曲目直接播，
                                // 歌单进歌单详情页，电台频道进 rail 详情页再下钻；
                                // 「展开」按钮仍开整条 rail 详情页。
                                // 喜欢 rail 的标题按当前平台取真名（displayTitle），
                                // 与来源 chip、空态文案、详情页标题同一份事实来源。
                                RailRowView(
                                    kind: kind,
                                    platform: viewModel.selectedPlatform,
                                    result: viewModel.rails[kind],
                                    isLoading: viewModel.railLoading[kind] ?? false,
                                    onExpand: {
                                        // r23 集成：需要登录的 rail 未登录时弹提示，不进详情。
                                        if let p = LoginGate.prompt(forRail: kind, platform: viewModel.selectedPlatform) {
                                            loginPrompt = p
                                        } else {
                                            viewModel.openRail(kind)
                                        }
                                    },
                                    onRetry: {
                                        Task { await viewModel.loadRail(kind) }
                                    },
                                    onEntryTap: { entry in
                                        switch entry {
                                        case .track(let track):
                                            // 曲目卡：整份曲目进队列，从点中的起播
                                            // （与 RailDetailView 里点行一致）；
                                            // 播歌不设登录墙（取链/会员编排在
                                            // PlaybackStore 里）。
                                            let tracks = viewModel.rails[kind]?.tracks ?? []
                                            let idx = tracks.firstIndex(where: { $0.id == track.id && $0.platform == track.platform }) ?? 0
                                            playback.setQueue(tracks, startAt: idx)
                                        case .playlist(let playlist):
                                            // 歌单卡：直达歌单详情页（P2 已有
                                            // PlaylistDetailView）；收藏歌单
                                            // rail 的登录墙与「展开」同一套。
                                            if let p = LoginGate.prompt(forRail: kind, platform: viewModel.selectedPlatform) {
                                                loginPrompt = p
                                            } else {
                                                nav.show(.playlist(platform: playlist.source, id: playlist.id, isRank: playlist.isRank))
                                            }
                                        case .station:
                                            // 电台频道卡：没有单频道直达页，进整条
                                            // rail 详情页再点频道下钻（与「展开」一致）。
                                            if let p = LoginGate.prompt(forRail: kind, platform: viewModel.selectedPlatform) {
                                                loginPrompt = p
                                            } else {
                                                viewModel.openRail(kind)
                                            }
                                        case .groupHeader:
                                            break
                                        }
                                    }
                                )
                                .padding(.horizontal, 16)
                                if viewModel.selectedSource == .playlists {
                                    MyAlbumsEntryView()
                                        .padding(.horizontal, 16)
                                }
                            }

                            LocalMusicSectionView()
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
        // 不按安全区顶；首屏两块拼满整屏——忽略顶部与底部安全区后
        // GeometryReader 原点 = 屏顶、size = 整屏（390×844 档 viewHeight
        // 从 781 变 874，Hero 高随之变，见驱动 2b；sizeTier 只看宽度，
        // 不受影响；"liziHome" 坐标系与环覆盖层同系，相对位置不变）。
        // 底部留白由内容自己留 50（16 净空 + 34 Home Indicator），
        // 不靠系统安全区（否则首屏底边对不上模板的屏底线）。
        .ignoresSafeArea(edges: [.top, .bottom])
        // r23 集成：登录提示 alert + 「去登录」 sheet（rail 展开用）。
        .loginRequiredAlert(prompt: $loginPrompt, loginTarget: $loginTarget)
        .sheet(item: $loginTarget) { LoginSheetView(platform: $0.platform) }
        .task {
            // r24 第 1 件：首页启动就刷一次登录态（fire-and-forget，
            // 不等它回来再 initialLoad——7 个 status 并行刷，各自失败
            // 互不影响）。不刷的后果：LoginStore.states 初始全是未登录，
            // 冷启动后 LoginGate 会把已登录用户的歌单/喜欢 rail 也拦在
            // 「需要登录」提示外，直到用户进一次设置页才恢复
            // （用户 08:35「歌单都无法调取」的另一根因）。
            // 节流在 LoginStore.refresh() 里（60 秒内只刷一次），
            // 回首页重建 HomeView 不会每次都并行打 7 个 status。
            LoginStore.shared.refresh()
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
        .onChange(of: viewModel.selectedRail) { selection in
            // P2 集成缝合：rail 详情不再用 sheet，改走 AppNavigation（工人 A 已落地
            // .rail(kind:platform:)），与其它详情页同一套导航；选完即清掉触发态。
            if let selection {
                nav.show(.rail(kind: selection.kind.rawValue, platform: selection.platform))
                viewModel.selectedRail = nil
            }
        }
        .onChange(of: playback.currentTrack) { track in
            if let track = track {
                Task { @MainActor in viewModel.notePlayed(track) }
            }
        }
        .onChange(of: playback.isLiked) { _ in
            // 星标变了：正在看喜欢 rail 时刷新该 rail（本地星标兜底的平台
            // 靠这一刷把新点的星标列进来）。
            if viewModel.selectedSource == .liked {
                Task { await viewModel.loadRail(.liked) }
            }
        }
    }

    /// r22j：铺色面板底色 = 当前平台品牌色 10% 淡 tint（壳版 `#hall-plat`
    /// 是平台色 Grainient 满铺；原生浅色卡片 + 墨字要留着，只能淡 tint 近似）。
    /// 品牌色取 `LiziPlatforms.Info.brandHex`（与壳版 `PLAT_BG` 同值，
    /// 见 HomeViewModel.swift 底部清单）；未知平台回落壳版同款灰 #8A8A8A。
    private var platTint: Color {
        let info = LiziPlatforms.all.first(where: { $0.id == viewModel.selectedPlatform })
        return Color(hex: info?.brandHex ?? 0x8A8A8A).opacity(0.10)
    }

    /// 每日推荐铺色面板（模板 v2 定高窗，壳版 `#hall-plat` 内容）：
    /// 圆角 22、内边距 10、底色 platTint；只有环在窗内竖滑（标准档内容
    /// 约 403，高于竖屏面板 382、更高于横屏 140；模板里面板封面本来
    /// 就是齐底边裁断的）。竖屏顺序：条 → chips → 环；横屏顺序：条 →
    /// 环 → chips（横屏面板只有约 140 高，先让封面露出来、与模板一致；
    /// chips 在下面，滑下去才见）。
    /// r23h：平台条 +（竖屏）chips 行钉在面板顶、不进竖滑 ScrollView——
    /// 面板是定高窗、内容比窗高，放歌后环内容一换（每日 → 队列）或手指
    /// 在面板里竖滑，ScrollView 的偏移会把条和 chips 顶出窗外、再也滑
    /// 不回来（07:09 真机：条 + chips 全没了、环还在）；钉在外面后偏移
    /// 再怎么变也顶不走它们。横屏面板只有约 140 高、模板要求先露封面，
    /// chips 仍放环下面的竖滑区里（模板原意：滑下去才见），只钉平台条。
    /// 真机风险：面板内竖滑与环的上滑展开手势竞争——环的展开用 UIKit
    /// pan recognizer（见 HomeCoverRingView，r21 教训后不再用 SwiftUI
    /// DragGesture），它与外层 ScrollView 竖滑共存；现在多了一层面板内
    /// ScrollView，展开手势是否仍优先，要真机验（见清单 D19）。
    /// r22l 编译修：真类型名是 PlayerTokens.PlayerSizeTier
    ///（PlayerTokens.swift 里 `enum PlayerSizeTier`，r20 约定名），
    /// 之前写的 SizeTier 不存在。
    private func dailyPanel(
        width: CGFloat,
        height: CGFloat,
        isLandscape: Bool,
        tier: PlayerTokens.PlayerSizeTier
    ) -> some View {
        // r23h：条 +（竖屏）chips 钉在面板顶，见本函数头注释。
        VStack(spacing: 8) {
            PlatformStripView(viewModel: viewModel)
            if isLandscape {
                // 横屏先环后 chips：封面先露出来（模板 v2 横屏面板里
                // 一排封面卡在第一屏；chips 在下面，滑下去才见）。
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        HomeCoverRingView(
                            model: ringModel,
                            dailyTracks: viewModel.daily.map { $0.track },
                            isLoadingDaily: viewModel.isLoadingDaily,
                            dailyEmptyReason: viewModel.dailyEmptyReason,
                            marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                            tier: tier
                        )
                        SourceChipsView(viewModel: viewModel)
                    }
                }
            } else {
                SourceChipsView(viewModel: viewModel)
                // r21：首页 3D 封面环（平面跑马带常态 + 上滑展开全屏圆环；
                // 见 HomeCoverRingView 文件头视频逐帧规格）。
                // 内容是播放队列（非空时）或每日推荐（队列为空时），
                // 两份都空时不显示。环本身的实现是另一个工人的，
                // 本轮只动它在面板里的位置，不动 HomeCoverRingView.swift。
                ScrollView(.vertical, showsIndicators: false) {
                    HomeCoverRingView(
                        model: ringModel,
                        dailyTracks: viewModel.daily.map { $0.track },
                        isLoadingDaily: viewModel.isLoadingDaily,
                        dailyEmptyReason: viewModel.dailyEmptyReason,
                        marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                        tier: tier
                    )
                }
            }
        }
        .padding(10)
        .frame(width: width, height: height)
        .background(platTint)
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius22))
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
    /// 三样 gap 9（壳版 `.brand` gap 9px）、整体居中。
    ///
    /// 居中做法：HStack（左列按钮 + Spacer）+ `.overlay(alignment:
    /// .center)` 放品牌——overlay 以整行全宽为基准居中，品牌不随左列
    /// 宽度偏左或偏右；不用 ZStack（尺寸歧义，r22j 旧版已换掉）。
    ///
    /// 按钮画完整（用户 05:08「设置和搜索按钮要画完整」）：齿轮字形 30、
    /// 搜索字形 28（模板量齿轮 34、搜索 30，留边距各收 4pt；38pt 框、
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
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(LiziTokens.ink2)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("设置")
            Button(action: { nav.show(.search) }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
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
            HStack(alignment: .center, spacing: 9) {
                BrandMarkView()
                BrandWordView()
                Text("kun")
                    .font(.custom("Fraunces", size: 11).italic().weight(.medium))
                    .tracking(0.22) // 壳版 `.brand__air` letter-spacing .02em × 11px
                    .foregroundColor(LiziTokens.ink2)
                    .offset(y: 2) // 壳版 `.brand__air` translateY(2px)，往下移 2pt
            }
        }
        .padding(.top, topPad) // 品牌纵向中心 = topPad + 32（屏顶起算，见上）
    }
}

/// r24 分界手柄（只画样子，手势挂在 HomeView 里 overlay 处）：
/// 28pt 高的透明触摸区（`.contentShape(Rectangle())` 保证整块都吃触摸，
/// Color.clear 本身不画东西）+ 中间一条 36×4 圆角胶囊（低对比度墨色）。
/// 不加任何缩放手势、不加 scaleEffect——只改两块高度分配。
private struct HomeResizeHandle: View {
    var body: some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 2)
                .fill(LiziTokens.ink.opacity(0.28))
                .frame(width: 36, height: 4)
        }
        .contentShape(Rectangle())
    }
}

/// 品牌 LI 标记：SwiftUI Path 按壳版 `public/index.html` 内联 SVG 照抄
/// （`viewBox="328 329 368 366"`，17×17，4 个 polygon，坐标一个数都不改；
/// 只是先平移 viewBox 原点、再缩放到 17pt——Path 里的数字就是壳版原数）。
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
        .transform(CGAffineTransform(translationX: -328, y: -329)
            .scaledBy(x: 17 / 368, y: 17 / 366))
        .fill(LiziTokens.ink)
        .frame(width: 17, height: 17)
    }
}

/// 品牌 LIZI 四个字母：SwiftUI Path 按壳版 `public/index.html` 内联 SVG
/// 照抄（`viewBox="0 0 224 100"`，34×15；L = polygon，I = rect，
/// Z = rect + polygon + rect，I = rect；坐标一个数都不改）。
/// 不是字体打出来的（壳版本来就不是字体，是多边形），不是图片资源。
private struct BrandWordView: View {
    var body: some View {
        Path { path in
            // L：polygon (0,0 19,0 19,81 47,81 66,100 0,100)
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 19, y: 0))
            path.addLine(to: CGPoint(x: 19, y: 81))
            path.addLine(to: CGPoint(x: 47, y: 81))
            path.addLine(to: CGPoint(x: 66, y: 100))
            path.addLine(to: CGPoint(x: 0, y: 100))
            path.closeSubpath()
            // I：rect x84 y0 w19 h100
            path.addRect(CGRect(x: 84, y: 0, width: 19, height: 100))
            // Z：rect(121,0,66,18) + polygon(169,18 187,18 139,82 121,82)
            //    + rect(121,82,66,18)
            path.addRect(CGRect(x: 121, y: 0, width: 66, height: 18))
            path.move(to: CGPoint(x: 169, y: 18))
            path.addLine(to: CGPoint(x: 187, y: 18))
            path.addLine(to: CGPoint(x: 139, y: 82))
            path.addLine(to: CGPoint(x: 121, y: 82))
            path.closeSubpath()
            path.addRect(CGRect(x: 121, y: 82, width: 66, height: 18))
            // I：rect x205 y0 w19 h100
            path.addRect(CGRect(x: 205, y: 0, width: 19, height: 100))
        }
        .transform(CGAffineTransform(scaleX: 34 / 224, y: 15 / 100))
        .fill(LiziTokens.ink)
        .frame(width: 34, height: 15)
    }
}

/// 一条 rail 的行（P2）：标题 + 横向卡片 + 点开展开。
///
/// - 标题行：rail 名 + 右侧「展开」按钮（有内容时才显示）。
/// - 卡片：曲目卡（封面 + 歌名 + 歌手）/ 歌单卡 / 电台频道卡
///   （封面 + 名字 + 副标题）；分组说明卡（groupHeader）只在详情页出现，
///   行里跳过。点卡片按类型直达（r24 第 1 件；原来不管点哪张卡都只调
///   onExpand 开整条 rail 列表，点歌单看不到那张歌单——用户 08:36
///   「歌单点了都没反应」的其中一根因）：
///   曲目卡 → 直接整份进队列从点中的起播；歌单卡 → 歌单详情页
///   （PlaylistDetailView，经 AppNavigation.playlist）；电台频道卡 →
///   整条 rail 详情页（频道下钻在 RailDetailView 里，没有单频道直达页）。
///   歌单 / 电台的登录墙在调用方（HomeView）的 onEntryTap 里判，
///   与「展开」按钮同一套 LoginGate，不在这里另起判定。
/// - 空态：请求失败显示失败原因 + 重试；内容为空显示诚实原因
///   （未登录 / 接口缺失 / 本地星标为空三种原因分开写，不都写「暂无内容」）。
/// - 封面无图用白色底 + 音符占位（CoverImageView）；禁缩放（不加任何
///   magnification 手势）。
private struct RailRowView: View {
    let kind: RailKind
    /// 当前平台：喜欢 rail 的标题按平台取真名（`displayTitle`），
    /// 不能只凭 kind 定。
    let platform: String
    let result: RailResult?
    let isLoading: Bool
    let onExpand: () -> Void
    let onRetry: () -> Void
    /// 点卡片的直达回调（r24 第 1 件）：曲目 → 播，歌单 → 歌单详情页，
    /// 电台频道 → rail 详情页；与「展开」按钮的 onExpand 分开。
    /// r24 构建修（run 44656645107）：第 1 件工人只写了上面这段注释与
    /// 下面的调用点，漏声明了本属性，编译器报 "cannot find 'onEntryTap'
    /// in scope"；这里补上声明，调用方 HomeView.body 已传实参。
    let onEntryTap: (RailEntry) -> Void

    /// 行标题（喜欢 rail 按平台取真名，其余 rail 固定名）。
    private var displayTitle: String { kind.displayTitle(platform: platform) }

    /// 行里只放可点的卡片，分组说明卡跳过（只在详情页出现）。
    private var cards: [RailEntry] {
        (result?.entries ?? []).filter {
            if case .groupHeader = $0 { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(displayTitle)
                    .font(.liziDisplay(size: LiziTokens.size20))
                    .foregroundColor(LiziTokens.ink)
                Spacer()
                if !cards.isEmpty {
                    Button(action: onExpand) {
                        HStack(spacing: 4) {
                            Text("展开")
                                .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(LiziTokens.ink2)
                    }
                    .accessibilityLabel("展开\(displayTitle)")
                }
            }
            Group {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在拉取\(displayTitle)…")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.ink3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else if let error = result?.error {
                    VStack(spacing: 8) {
                        Text(error)
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.accent)
                            .multilineTextAlignment(.center)
                        Button("重试", action: onRetry)
                            .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                            .foregroundColor(LiziTokens.ink2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                    .padding(.horizontal, 24)
                } else if cards.isEmpty {
                    Text(result?.emptyReason ?? "暂无内容。")
                        .font(.liziBody(size: LiziTokens.size13))
                        .foregroundColor(LiziTokens.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .padding(.horizontal, 24)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(cards) { entry in
                                Button(action: { onEntryTap(entry) }) {
                                    railCard(entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(railCardLabel(entry))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func railCard(_ entry: RailEntry) -> some View {
        switch entry {
        case .track(let track):
            VStack(alignment: .leading, spacing: 7) {
                CoverImageView(url: track.coverURL, placeholderIconSize: 28)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                Text(track.title)
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        case .playlist(let playlist):
            VStack(alignment: .leading, spacing: 7) {
                CoverImageView(url: playlist.coverURL, placeholderIconSize: 28)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                Text(playlist.title)
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(playlist.trackCount > 0 ? "\(playlist.trackCount) 首" : (playlist.creator.isEmpty ? "歌单" : playlist.creator))
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        case .station(let station):
            VStack(alignment: .leading, spacing: 7) {
                CoverImageView(url: station.coverURL, placeholderIconSize: 28)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                Text(station.name)
                    .font(.liziBody(size: LiziTokens.size14, weight: .medium))
                    .foregroundColor(LiziTokens.ink)
                    .lineLimit(1)
                Text(station.creator.isEmpty ? "电台" : station.creator)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(LiziTokens.ink3)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)
        case .groupHeader:
            EmptyView()
        }
    }

    private func railCardLabel(_ entry: RailEntry) -> String {
        switch entry {
        case .track(let track): return "打开\(displayTitle)：\(track.title)"
        case .playlist(let playlist): return "打开\(displayTitle)：\(playlist.title)"
        case .station(let station): return "打开\(displayTitle)：\(station.name)"
        case .groupHeader: return displayTitle
        }
    }
}

/// 「我的专辑」入口已由工人 C 的 MyAlbumsEntryView 接管（见 HomeView 收藏歌单 rail 区）。
