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
/// r31（用户 2026-11-21 05:33 + 跑马带卡顿追加）：6 个来源切到哪一个，
/// 面板里都要显示成卡片、跑马带一直自动滚。
/// - 现状（r30）：只有每日推荐是环/跑马带卡片；其余 5 栏是
///   `RailSourceListView` 的竖向列表（曲目 = TrackRowView 56pt 行，
///   歌单/电台 = 56pt 横行），没有跑马带——切过去卡片没了、带子停了。
///   本轮把 5 栏改成与每日带同款的横向卡片跑马带（`RailMarqueeView`，
///   卡 = 封面 + 名 + 副标题；曲目卡点播，歌单/电台卡就是集合本身，
///   点进详情/电台页；分组说明卡不进带子），加载/失败/空态三态、
///   「查看全部」、混列脚注原样保留；面板头、取色、本地音乐、3D 环不动。
/// - 跑马带卡顿同修（见 HomeCoverRingView.swift 文件头 r31 节）：
///   驱动从 30Hz Timer（0.8px/步离散跳变 + Task 跳主线程抖动）改成
///   CADisplayLink + 真实帧间隔 dt（60Hz 约 0.4px/步、120Hz 约 0.2px/步），
///   环平面带与 rail 带共用这一套；rail 驱动归 HomeView 所有
///   （`railMarqueeDriver` @StateObject），`.id(selectedSource)` 只重建
///   sourceContent、驱动不重建，切来源后 offset 不归零、不重停 2.5s，
///   接着滚。3D 环还是只手滑展开、不自动开，不动。
///
/// r31 后续（用户 2026-11-21 06:02–06:05，四件同区落地，见
/// HomeViewModel.swift 文件头 r31 节）：来源剩 5 项，「用户收藏」删掉
/// （数据并进「我喜欢」）、「用户创建的歌单」改名「我的歌单」（只留自建）；
/// 混列脚注随分流撤掉（各家现按 subscribed / isOwned 标记真分自建与收藏，
/// 不再是同一份混列）；「我的歌单」/「我喜欢」里的歌单或专辑卡点后在
/// 面板内打开（`RailSourceListView.openedView`：该集合全部歌曲卡片，
/// 跑马带同驱动同速接着滚，返回键回列表），其余来源的歌单卡仍进详情页。
///
/// r31-marquee（用户 2026-11-21 06:25「跑马带里的卡片现在是卡着的，
/// 不会一直向左滑」）：根因两处，都在本文件的 rail 驱动 + 两处代理
/// （环平面带见 HomeCoverRingView.swift 文件头 r31-marquee 节）：
/// 1. 硬停：`RailMarqueeDriver.isDragging` 只有一个出口
///    （DragGesture.onEnded）；手势被打断（切来源/切平台/打开歌单时
///    视图被拆、App 切后台、来电、滚动接管）时 onEnded 到不了，旗子
///    永远卡住、带子永远停——r26 每日带就是这副样子，本轮 rail 驱动
///    照抄了 r26 之前没看门狗的形状。修法（只动驱动）：linkFired 里
///    加 10s 看门狗（与环 `tickFlat` 同款）+ 视图被拆时
///    `dragCancelled()`（`RailMarqueeView.onDisappear` 调，不推 dwell）。
///    第二推（登录态）查过：它没碰驱动（没调 start / 没写 isDragging /
///    没停 display link），只改了来源数与面板内打开——但面板内打开
///    多了一条视图拆建路径，让本来的单出口更容易撞上。
/// 2. 一卡一卡：两处代理回调都经 `Task { @MainActor in }` 跳主线程——
///    display link 已挂在 RunLoop.main 上，回调本身就在主线程；每帧
///    一个 Task 让步长在任务队列里扎堆（几帧的量一次走完、再空几帧），
///    dt 还是在 Task 里读的 link.timestamp（已更新的戳）。r31 第一推
///    文件头写的是「去掉 Task 跳线程」，代码里其实还留着，本轮才真去掉：
///    代理直接调 tick（`MainActor.assumeIsolated`，link 只加在 .main 上，
///    回调只可能在主线程）。速度 24px/s、dt 夹 0.1s、回卷归一化、
///    初画 2.5s、松手 1.2s 一律不动。驱动见 verification/r31-marquee.cjs。
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
/// heroFractionPortraitKey / heroFractionLandscapeKey（竖屏默认 0.206、
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
/// 2. 竖屏按壳版视频排（r28；402×874 档）：顶栏区 95 + 间距 14 +
///    Hero 152 + 间隙 27 + 面板（内容封顶 407）= 695，余下是本地音乐
///    （壳版视频里本地音乐就露在首屏）；横屏 Hero 横幅 + 面板上下叠
///    （932×430 档：顶栏 64 + 间距 26 + Hero 180 + 间距 20 + 面板 140 = 430）。
///    Hero 高 = contentH × fraction（竖屏默认 0.206，见 loadHeroFraction），
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
///    其余来源 = rail 卡片跑马带 RailSourceListView），同一块圆角面板里，
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
///
/// r31-landscape（用户 2026-11-21 06:29 横屏卡死 + 06:30 竖屏卡片滑不到顶，
/// 06:30 确认是同一个问题；06:31 截图：竖屏 Hero「复刻回忆」在顶、面板两张
/// 大卡「尚可」「山楂树の恋」，再往上滑就顶住、卡片上不去）：
/// 唯一根因——首页外层 ScrollView 滚不动，卡在面板那一层，两件都是它：
/// 1. 手势被抢（主因，横屏卡死与竖屏顶住都是它）：`dailyRingContent` 里
///    包了一层竖向 ScrollView（面板内竖滑）。同向嵌套 ScrollView，
///    面板里的竖向拖动全被内层吃掉，外层一次都轮不到——SwiftUI/UIKit
///    里内层滚动视图的 pan 优先认领同一根触摸，外层 pan 被取消。
///    `StripTouchView` 的 `shouldBeRequiredToFailBy`（HomeCoverRingView，
///    未动）还让外层 pan 必须等环触摸层先失败，内层 pan 判向失败后先
///    认领，等于判了外层死刑。竖屏内层根本滚不动：环内容 283pt <
///    面板窗 331pt，行程 0，手指在卡片上一滑只剩内层回弹；
///    横屏内层先滚完自己的 255.5pt 才停，外层始终不动——页面看着卡死。
///    不是主线程堵：跑马带 CADisplayLink 每帧只改 0.4px offset，
///    取色 32×32/k=4 只在切歌时跑一次；卡住的位置是确定的（内层行程
///    尽头 / 最大偏移），不是随机卡顿。
/// 2. 行程不够（竖屏「滑不到顶」差的那一段）：竖屏 390×844 标准档，
///    面板顶滑到顶栏下要 218.3pt 偏移，内容只比视口高 112.3pt——
///    哪怕手势修好，卡片也只能到半屏（面板顶停在 y≈201），到不了顶。
///    402×874 差 136pt；横屏 844×390 行程够（236 > 203.5），不差。
/// 修法（只动本文件，两处，都在外层 ScrollView 这一条线上）：
/// ① 拆掉 `dailyRingContent` 的内层竖向 ScrollView，竖滑归外层整页
///    （r30 定好的意图当时没做到，这次做实）；面板框加顶对齐
///    （`.frame(…, alignment: .top)`），环内容超出横屏面板窗的部分
///    由面板圆角裁掉（模板原意「齐底边裁断」），平台条钉在面板顶不动。
///    拆完后环触摸层竖向判向失败照常交还——这次交还的对象只剩外层，
///    页面接着滚；横向仍开环、点按仍播歌，环手势不动。
/// ② 底部留白改成 `homeBottomPad`（底数 50 不变）：量到外层内容实高后
///    按公式重算，行程不够就补底边距凑到「面板顶 + 8pt 越过量」，
///    行程够了缩回 50（幂等，不震荡；旋转/本地音乐展开后自动重算）。
///    390×844 → 164.0，402×874 → 194.0，横屏 → 50 不变。
///    竖屏 Hero / 面板高度、尺寸分档、取色、本地音乐、两卡拖动、
///    跑马带速度一律不动。驱动见 verification/r31-landscape.cjs。
///
/// r31-imagebg（用户 2026-11-21 07:15：静态图片背景 + 动态壁纸）：
/// 首页/大厅背景层是 `HomeBackgroundView`（BackgroundView.swift，
/// 状态在 `BackgroundStore`）：挂在最外层 GeometryReader 的
/// `.background` 里，在全部内容之下；滚动区的 `.background` 改透明，
/// 不再盖一层纸色。默认模式就是原来的纸色（视觉与 r30 一致）；
/// 静态图片 = 沙盒图铺满 + 轻模糊 + 浅色可读性蒙版；
/// 动态壁纸 = 沙盒视频 AVPlayer 静音循环 + 同款蒙版。
/// 蒙版为什么是浅色不是深色压暗：全站文字是深色墨字，深色压暗会反让
/// 顶栏品牌/齿轮/搜索看不清（见 BackgroundView.swift 文件头）。
/// Hero/面板/本地音乐本身是不透明卡片，不受背景层影响。
///
/// r33-download-entry（用户 2026-11-21 10:25 取消）：首页不放下载管理入口，
/// 这里的卡已删；下载管理功能本身（DownloadsView）不动，入口只剩设置页
/// 「存储与下载」分区与播放页底部下载键。
///
/// r33-home-hero-up（用户 2026-11-21 真机截图：顶栏与 Hero 之间约 80pt
/// 空米色带，Hero 顶离屏顶约 141pt）：竖屏 gapTop 46→14，Hero 顶收到
/// 顶栏下 14pt（109pt）；默认 fraction 0.215→0.206，contentH 738 档
/// Hero 仍约 152pt；gapMid 27 不动，面板跟着上移 32pt（顶 320→288pt，
/// 高仍封顶 407）。横屏 gapTop 26 不动；顶栏不动；拖动改尺寸、持久化
/// key、min/max 夹值一律不动，已存 fraction 不受影响。
/// 下滑停止点（用户 10:18 截图：滑到底面板顶贴在顶栏下、约 97pt）：
/// homeBottomPad 公式 +8pt 越过量改 −2pt，最大滚动量把面板顶送到
/// 顶栏下沿之下 2pt 即停，不再多滑出空白；横屏仍 50、不变。
/// （r35-5 起这条作废，见下。）
/// r35-3（用户 2026-11-21 18:36「新增搜索之后播放的歌单列表」；18:37 补
/// 「卡片形式一直从左到右滑动」，18:40 更正为「向左滚，跟首页跑马带同方向」；
/// 18:49 用户又说「正在播放也是放到今日推荐里面，而不是单独做一个出来」，
/// 18:51 更正：18:49 那句说的不是首页 Hero，是搜索这件——搜完点歌播起来后，
/// 正在播放的歌单列表放在今日推荐面板里面，而不是单独另做一个独立的歌单
/// 页面/独立卡片；首页 Hero 大卡、两卡拖动一律不动，18:49 的首页改动作废）：
/// 模型：PlaybackStore.queueTitle（@Published，只在内存里，不写 UserDefaults、
/// 不进「我的歌单」）+ setQueue 可选标题参数（默认 nil，其他调用点不动）；
/// 搜索点歌传「搜索：\(query)」。呈现：队列面板恢复原样（List），歌单带放在
/// 今日推荐面板顶上一块（dailyPanel 的 searchQueueBlock）：标题行（歌单名 +
/// 共 N 首）+ 横排卡片跑马带，直接复用首页 RailMarqueeView / RailMarqueeDriver
/// （另起一个驱动实例，卡宽 96 紧凑档，速度跟首页跑马带走），当前播的高亮
/// （RailMarqueeCard.isCurrent，rail 各栏默认 false、渲染不动），点卡切歌
/// （store.play(queueItem:)，按 queueId 定位）。面板封顶有这块时抬高 252
/// （带块 184 + 置顶行 68），不然每日内容的底边会被裁掉。搜新词点新歌时
/// setQueue 整队替换，标题与带子一起换成新的；切到别的歌单点歌、清空队列时标题消失、块跟着消失。
/// r35-3（补充，19:21「正在播放点击播放了就自动置顶在今日推荐上面」）：
/// 点歌播起来后，正在播放的那首钉在面板最上面（dailyPanel 的
/// nowPlayingPinBlock，置顶行：封面 48 + 歌名/歌手 + 播放/暂停钮，点行进
/// 播放页 HeroCardView 同款 showClassicPlayer()）；切歌时 currentTrack 跟着
/// 换，置顶跟着换。只动面板里头，Hero 大卡、本地音乐、顶栏一字不动。
/// 驱动见 verification/r35.cjs §J。
/// r35-4（用户 2026-11-21 18:42「修复这个下面卡片无法滑到顶部的问题」，
/// 澄清是下面每日推荐那张卡片；18:43 补「要能把上面正在播放的卡片拖消失」）：
/// 分界手柄往上拖，Hero 高一路收到 0（整张消失），面板顶到内容顶
/// （顶栏下 gapTop + gapMid，竖屏 41pt、屏 y 136）；往下拖回来，Hero
/// 再出来。松手停在哪就是哪，不回弹、不吸附；Hero 消失时正在播的歌不停
/// （只收卡片，不动 PlaybackStore；播放钮在卡片里，卡片收起来就看不见，
/// 播放在后台继续，点面板里别的入口还能回去）。
/// 两处改动：① minHeroH 131pt 死下限删掉，改成 0——旧下限是按 Hero 内
/// 边距 + 顶行 + 底行算出来的「卡片内容完整高」，拖到底 Hero 还剩 131pt，
/// 面板顶永远到不了顶部，就是拦路的那块；② loadHeroFraction 接受存过的
/// 0（double(forKey:) 缺键与存 0 都回 0.0，先拿 object(forKey:) 判有没有
/// 存过，不然拖到 0、杀掉重进又变回默认 0.206）。Hero 高为 0 时
/// HeroCardView 自身的 clipShape 把内容裁成 0 高、不溢出面板；
/// 持久化照旧（松手写当前方向的 key，0 也写）。
/// r35-5（用户 2026-11-21 18:44「还有这个下滑太长了」，「确保能滑动到
/// 显示本地音乐就行」）：往下滑到底，本地音乐（标题 + 文件夹卡 +
/// 导入按钮）完整显示就停，下面不再多出一大片空白。根因就是 r31 的
/// homeBottomPad 重算：标准档补到 154pt，滑到底时导入钮下面正好多出
/// 154pt 空白（导入钮在视口 y 551–595，视口 749）。修法：底边距固定
/// 50 不再重算（量内容实高的 GeometryReader + onPreferenceChange +
/// HomeContentHeightKey 一并删掉）；滑到底导入钮在视口 y 655–699，
/// 下面只剩 50pt（16 净空 + 34 Home Indicator）。
/// 两件是同一块底边距的两面：面板顶要贴顶栏下（约 97pt），底边距非补到
/// 154 不可——不变性：需补的边距 = 视口 − 面板 − 24 − 本地音乐 − 2，
/// 与 Hero 高无关（Hero 收小多少，need 与内容同减多少，154 一分不少；
/// Hero 收到 0 也一样）。所以 97pt 那条线与「下面没空白」不能同时要：
/// r35 起面板到顶的路只走分界手柄（Hero 拖到 0，面板顶到内容顶），
/// 不再靠底边距撑滚动行程；r31/r33 的「最大滚动量把面板顶送到顶栏下」
/// 与 −2pt 停止点随重算一起作废。驱动见 verification/r35.cjs §K/§L。
/// r35-10（用户 2026-11-21 19:17「新增排行榜，按 Moumusic 的做法做」；
/// 19:19–19:21 落点：排行榜放进今日推荐面板里头，作为面板顶部的一块，
/// 跟搜索歌单列表那块并列（搜歌块在上、榜单块在下，都在平台条上面）；
/// 不单独开一栏、不动精选/喜欢/歌单/电台那几栏；只动面板里头，Hero
/// 大卡、本地音乐、顶栏、设置、播放页、搜索页一律不动；没榜的平台
/// 老实写没有，不编假榜）：
/// 模型：NativeBridge.rankBoards(platform:)（网易 eapi /toplist、QQ
/// musicu GetAll、酷狗 rank/list、酷我已有 /api/kuwo/rank/list；波点
/// 接口已死、汽水/Apple Music 没有榜单目录——不发请求，只画诚实文案）
/// + HomeDataCache.rank（按平台分键当日有效，空结果 5 分钟否定缓存，
/// 与每日推荐同款）+ HomeViewModel.loadRankBoards（缓存优先、250ms
/// spinner、代际守卫，切台同批起）。呈现：dailyPanel 的 rankBlock：
/// 标题行（「排行榜 · 平台名」+ 右侧「共 N 个榜」）+ 横排卡片跑马带，
/// 照 searchQueueBlock 抄形态（另起一个驱动实例 rankMarqueeDriver，
/// 卡宽 96，速度跟首页跑马带走）；点卡进详情页（isRank: true，行首
/// 显示排名数字，页头拿目录卡片的标题/封面当种子）。面板封顶有这块时
/// 再抬 184（有榜）或约 48（没榜，只画标题行 + 诚实文案）。
/// 驱动见 verification/r35.cjs §Q。
/// r36-2（用户 2026-11-21 21:09 截图定落点：「排行榜是加到这里面」——
/// 今日推荐面板上方弹出的切换菜单，5 行：每日推荐（已打勾 ✓）、精选、
/// 本地星标收藏、我的歌单、电台；菜单后面透出的面板卡片是 P500、内地榜）：
/// 排行榜从面板里的一块改成切换菜单里的一项（第 6 行「排行榜」），点它
/// 切到排行榜面板（面板内容 = 当前平台的榜单列表，卡片就是截图里那种
/// 榜单卡，点卡进详情复用 r35 路由）。拆掉：dailyPanel 里的 rankBlock
/// 引用、rankBlock 本体、rankMarqueeDriver（榜单带改共用 railMarqueeDriver——
/// 同一时间只有一个来源的带子可见，RailMarqueeView.onAppear/onChange
/// 调 noteContentChanged() 把偏移归一化进新宽度，不抢 setWidth）、
/// rankBeltExtraH 封顶（panelContentH 回到 flatCard + 217 +
/// searchBeltExtraH）、rankBlock 的标题行（条上已显示「排行榜」，
/// selectedPlatformName 随之删）。菜单勾选态是通用逻辑（page ==
/// selectedSource 打勾），.rank 进 allCases 自动跟随。取数层不动：
/// loadRankBoards 仍随每日推荐同批起、缓存恢复照旧，切到排行榜直接画，
/// 不现拉；没榜的平台照旧只画诚实文案。驱动见 verification/r36.cjs §H。
/// r36（用户 21:25 参照图）：榜单带卡宽改成与首页环平面带同档
/// （flatCard：compact 180 / standard 190 / large 209），大封面卡片
/// 横向轮播——真封面、当前大张居中、左右露出相邻封面、封面下榜单名；
/// 点卡进详情路由原样保留。驱动见 verification/r36-landscape.cjs §F。
/// r36 v4（用户 21:45 批「对就是这样」，稿图 lizi-chart-detail-mockup.png）：
/// 点榜单卡不再跳独立详情页——面板内换成该榜单的全部歌（rankDetailContent：
/// v4 顶栏只留榜单名 + 返回「‹ 榜单」+ 搜索，轮播是首页环，卡片正常显示
/// 无排名数字、无总数、无提示文字，点卡播歌）；平台条在详情态隐藏。
///
/// r37-1（用户 2026-11-22 00:30 定稿，稿图 ~/workspace/lizi-home-panel-mockup.png；
/// 00:31 用户长期规则：不要多加东西、不要乱改以前的东西，各模式内容按本来样子
/// 正常显示在卡片里面）——首页面板常驻、只一个排版：
/// - 面板 = 顶栏（`PlatformStripView`：当前模式名 + ⌄ + 平台图标 + 右边搜索）
///   + 一排封面卡片。顶栏钉在面板顶、全程常驻：面板里原先压在顶栏上面的两块
///   （r35-3 的正在播放置顶行 `nowPlayingPinBlock`、搜索歌单带 `searchQueueBlock`）
///   已删（置顶行带歌名/歌手 + 播放/暂停钮，与「卡片只放封面、没有暂停键」冲突；
///   两块占着面板顶，Hero 拖大、面板缩小时顶栏会被顶出定高窗、看不见），
///   榜单详情态也不再隐藏顶栏（r36 v4 的 `selectedRankBoard == nil` 守卫已删，
///   顶栏和菜单一直在，随时能点回今日推荐或用户自建歌单）；榜单详情自己的顶行
///   （榜单名 + 返回「‹ 榜单」+ 搜索）原样保留。面板本身仍随整页滚动
///   （r35-5：滑到底显示本地音乐），常驻指的是面板里的顶栏与卡片行在首页
///   一直都在、滚动时不被面板内其他块顶走，不是把顶栏钉在屏幕顶。
/// - 卡片只放封面图：面板里全部卡片（每日环平面带 `FlatRingCard`、rail 跑马带
///   `RailMarqueeCardView`、排行榜目录卡、面板内榜单详情的环平面带）都不画
///   歌名/歌手文字、不放暂停键；点按行为不变（点封面就播那首 / 集合卡原路由）。
///   歌单详情页、搜索页等别处的标题不动；3D 环展开态的环卡（`RingCardView`）
///   标题不动——00:42:43 纠正：套壳版 1:1 复刻只限 3D 环卡，环卡按套壳版
///   （封面 + 歌名）显示；面板本身不按套壳版改显示/滑动逻辑。
///   入口提示行（「拖动展开 3D 环 · 拖动旋转」）不是卡片标题，原样保留。
///   封面-only 由 `HomeCoverRingView.coverOnly`（默认 false，每日推荐与面板内
///   榜单详情两路传 true）与 `RailMarqueeCardView` 去标题实现；卡宽与跑马带
///   机制不动（卡宽 180/190/209 与 3D 环几何、面板封顶公式耦合，稿图「第三张
///   露一半」是示意，现有一屏约 1.8 张、带子自滚 + 可拖，已能看出能滑，
///   改卡宽留待真机再定）。
///   r39-4（第 4 件，定稿 ~/workspace/lizi-r39-home-cards-mockup.png，
///   居中版）：上面「卡片只放封面」作废——面板里全部卡片卡下恢复歌名 +
///   演唱者两行（只加这两个，不加专辑名；歌名 16pt 粗体、演唱者 14pt，
///   居中对齐卡片；每日/正在播放/榜单详情走 `FlatRingCard`，其余 4 栏 +
///   排行榜目录走 `RailMarqueeCardView`；卡宽/卡高/间距不动，点按行为
///   不变）。3D 环卡标题、入口提示行不动；歌单详情页共用 `HomeCoverRingView`，
///   卡下两行字随同一组件改成居中 + 粗体 + 点中上抬（见交回）。
///   r37-1 追加（用户 2026-11-22 00:39 显示逻辑，长期规则）：封面没显示出来
///   时卡片先盖歌名/标题文字占位（白字盖在深色占位底上、盖在封面框里，不占卡高），
///   用户能先滑、认出是哪首歌；封面一到占位消失、只剩封面。占位只在封面未显示
///   时出现，不变常驻标题；无封面 URL 的卡永远无图可显，占位一直显示。
///   观测走 `CoverImageLoader` 进程内缓存（与 `CoverImageView` 同一份在飞任务，
///   不重复发请求；失败重试节拍照抄 `ProxyImageView`）。
/// - 搜索进卡片（r35-3 链路复用，不另起搜索结果页）：搜完点歌立起的队列
///   （`playback.queueTitle` + `playback.queue`，`setQueue(title:)` 透传）
///   不再另占一块带子；r38-1：它不再显示在每日推荐那一排卡片里（r37-1 的
///   searchQueue 覆盖已删，`dailyRingContent` 只显示 `viewModel.daily`），
///   改由菜单「正在播放」模式承载（`nowPlayingRingContent`：直播队列整条
///   就是当前播单，点卡切歌走环自带的 `setQueue(title:)`，队列标题不丢）。
///   搜索歌单带用的 `searchRingModel` 随 `searchQueueBlock` 一起删。
/// - 默认模式今日推荐（`HomeRailPage.daily`，持久化键无值时回落它，不改）；
///   模式菜单（`sourceMenuOverlay`，7 行：每日推荐/正在播放/精选/我喜欢的音乐/
///   我的歌单/电台/排行榜）与 `sourceTitle` 不动，切到哪个模式顶栏就显示
///   那个模式名 + ⌄，内容跟着换。Hero 大卡与本地音乐不动。
struct HomeView: View {
    @EnvironmentObject var playback: PlaybackStore
    @EnvironmentObject var nav: AppNavigation
    @StateObject private var viewModel = HomeViewModel()
    /// 首页环状态机（r21）：平面带与全屏环覆盖层共用（见 HomeCoverRingView 文件头）。
    @StateObject private var ringModel = HomeCoverRingModel()
    /// r36 v4（用户 21:45 批「对就是这样」，稿图 lizi-chart-detail-mockup.png）：
    /// 榜单详情在首页面板里——点榜单卡后，面板换成该榜单的全部歌
    /// （HomeCoverRingView 轮播），不再跳独立详情页。
    /// selectedRankBoard 为 nil 时面板显示榜单目录；非 nil 时显示该榜的歌。
    /// 切来源 / 切平台时清空（榜单是按平台的，见 sourceContent 的 onChange）。
    @State private var selectedRankBoard: RankBoard?
    /// 该榜单拉到的全部曲目（playlistDetail isRank，全量分页已在桥接层：
    /// 网易单次全量、QQ 上限 300、酷狗 10 页×100、酷我 10 页×200）。
    @State private var rankDetailTracks: [Track] = []
    /// 榜单曲目加载中（加载态只亮 spinner，不写文字——详情页不加提示）。
    @State private var rankDetailLoading = false
    /// r36 v4：榜单歌曲带的环状态机（独立实例，与每日推荐 ringModel
    /// 各用各的，两条带子内容不同不抢状态；r37-1：搜索带 searchRingModel
    /// 已随 searchQueueBlock 删掉；r38-1：搜索队列改由「正在播放」模式承载，
    /// 不再进每日推荐那排卡片）。
    @StateObject private var rankSongsRingModel = HomeCoverRingModel()
    /// r43-2：第 2 件——rail 四栏（精选/我喜欢的音乐/我的歌单/电台）+ 排行榜目录
    /// 共用的环状态机（独立实例，与每日推荐 ringModel / 榜单详情
    /// rankSongsRingModel 各用各的；同一时间只显示一个来源，entriesView 与
    /// openedView 切换时靠 cards 变化重同步，见 HomeCoverRingView.syncInputs）。
    @StateObject private var railRingModel = HomeCoverRingModel()
    /// r31：rail 来源跑马带驱动（`RailMarqueeDriver`，CADisplayLink + dt，
    /// 与环平面带同款）。归 HomeView 所有：dailyPanel 的
    /// `.id(viewModel.selectedSource)` 只重建 sourceContent，驱动不重建，
    /// 切来源后带子接着滚（offset 不归零、不重停 2.5s，见 `noteContentChanged`）。
    /// r36-2：排行榜面板的榜单带也共用它（rankMarqueeDriver 已删）——
    /// 同一时间只有一个来源的带子可见，内容换了只归一化偏移，不抢 setWidth。
    @StateObject private var railMarqueeDriver = RailMarqueeDriver()
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

    /// 读存值：没存过（object(forKey:) 为 nil）或非法（非有限、<0、≥1）
    /// 回落默认——竖屏 0.206（r28：39.6s 视频 Hero 约 152pt，
    /// contentH 706 档 152/706 ≈ 0.215；r33：gapTop 46→14 后 contentH
    /// 738 档 152/738 ≈ 0.206，Hero 仍约 152pt；旧 0.5 已作废）、横屏 9/16
    /// （0.5625，与 r23 前的模板公式同值）。
    /// r35-4：存过 0 就是 0（Hero 被拖到消失），不再当成「没存过」回落默认——
    /// double(forKey:) 缺键与存 0 都回 0.0，分不清，所以先拿 object(forKey:)
    /// 判有没有存过；0 是合法值（Hero 整张消失，面板顶到内容顶）。
    /// 读出后在 body 里再按当前 contentH 与上下限夹一次（见 minFrac / maxFrac）。
    private static func loadHeroFraction(landscape: Bool) -> CGFloat {
        let fallback: CGFloat = landscape ? 9.0 / 16.0 : 0.206
        let key = landscape ? heroFractionLandscapeKey : heroFractionPortraitKey
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw.isFinite, raw >= 0, raw < 1 else { return fallback }
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
    /// r35-5：首页底部留白固定 50（16 净空 + 34 Home Indicator，r28 原值），
    /// 不再重算——r31 的重算（量内容实高、行程不够就补底边距凑到「面板顶
    /// +8pt / −2pt」）已删：补出来的那 104pt（标准档 154−50）就是往下滑
    /// 到底时本地音乐下面的一大片空白；行程与空白是同一笔账（见文件头
    /// r35 节的不变性：面板顶要贴顶栏下，底边距非补到 154 不可，与 Hero
    /// 高无关），不能同时要。面板顶到顶部的路改走分界手柄（r35-4：Hero
    /// 拖到 0，面板顶到内容顶），不再靠底边距撑行程。
    @State private var homeBottomPad: CGFloat = 50
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

    /// r45-fix：分隔条拖动手势——从 body 里抽出来单独成函数。r45 首轮
    /// 构建时编译器报 HomeView.swift:679 类型检查超时（整条 body 大
    /// 表达式已到临界）；抽出来后 body 与手势各查各的。行为一字未动：
    /// 拖动改 Hero/面板比例、松手即停写当前方向的 key。
    /// 注意是函数不是计算属性：手势里用的 heroH / minHeroH / maxHeroH /
    /// contentH / isLandscape 都是 body 里 GeometryReader 的局部量，
    /// struct 层根本没有，计算属性里会报 cannot find in scope；改成
    /// 函数、调用时把这五个量传进来，闭包捕获方式与原来在 body 里内联
    /// 时完全一致——原来也是捕获 body 当次算出的局部 let，不是实时读。
    /// onEnded 里的 UserDefaults.set 也先拆成 let 再传（同款超时点，
    /// 不再把三元表达式直接塞进 set 的参数里）。
    private func dividerDragGesture(heroH: CGFloat, minHeroH: CGFloat, maxHeroH: CGFloat, contentH: CGFloat, isLandscape: Bool) -> some Gesture {
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
                let fractionToSave = Double(isLandscape ? heroFractionLandscape : heroFractionPortrait)
                let keyToSave = isLandscape ? Self.heroFractionLandscapeKey : Self.heroFractionPortraitKey
                UserDefaults.standard.set(fractionToSave, forKey: keyToSave)
            }
    }

    /// r45-fix：分隔条无障碍微调动作——与手势同款问题：二轮构建时超时点
    /// 移到这里（.accessibilityAdjustableAction 的闭包，HomeView.swift:691），
    /// 说明超时的是整条手柄修饰链、不是某一处 set()，只抽手势不够；
    /// 这个闭包也抽出来单独成函数。fraction / minFrac / maxFrac /
    /// isLandscape 同样是 body 局部量，调用时传进来，捕获方式与内联时一致。
    private func dividerAdjustAction(fraction: CGFloat, minFrac: CGFloat, maxFrac: CGFloat, isLandscape: Bool) -> (AccessibilityAdjustmentDirection) -> Void {
        { direction in
            let step: CGFloat = 0.05
            let next = min(max(fraction + (direction == .increment ? step : -step), minFrac), maxFrac)
            if isLandscape {
                heroFractionLandscape = next
            } else {
                heroFractionPortrait = next
            }
            let keyToSave = isLandscape ? Self.heroFractionLandscapeKey : Self.heroFractionPortraitKey
            UserDefaults.standard.set(Double(next), forKey: keyToSave)
        }
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
            // 间隙 27 + 面板（内容封顶 407）= 727，余下是本地音乐；
            // r33-home-hero-up：竖屏间距 46→14（Hero 顶 141→109pt），
            // 顶栏区 95 + 间距 14 + Hero 152 + 间隙 27 + 面板 407 = 695。
            // （壳版视频里本地音乐就露在首屏）；横屏：顶栏 64，
            // 间距 26，Hero 横幅 (430−110)×9/16 = 180，间距 20，
            // 面板 (430−110)×7/16 = 140，底边同样是屏底边。
            // 两块左右各留 16pt 边（模板量）；横屏顶栏左列按 leading 安全区
            // 往里收（见 topBar），Hero/面板本身不收（它们的顶在 90pt 以下，
            // 碰不到屏幕圆角）。
            let isLandscape = outer.size.width > outer.size.height
            let topPad: CGFloat = isLandscape ? 0 : 31
            let topBarH: CGFloat = 64
            let gapTop: CGFloat = isLandscape ? 26 : 14
            let gapMid: CGFloat = isLandscape ? 20 : 27
            let contentH = outer.size.height - topPad - topBarH - gapTop - gapMid
            // r24 两卡高度分配：heroH = contentH × fraction（按方向取各自的
            // @State），panelH = contentH − heroH，总高不变、首屏仍拼满。
            // tier 在这里算一次，minPanelH 与 dailyPanel 共用。
            let tier = PlayerTokens.sizeTier(for: outer.size, topInset: outer.safeAreaInsets.top)
            // r24 上下限（数都从代码量出来，见各行注释；fraction 的合法夹取
            // 区间就是 [minHeroH, maxHeroH] 换算成的比例）：
            // - minHeroH：r35-4 起为 0——分界手柄往上拖可以把 Hero 一路
            //   收到 0（整张消失），面板顶到内容顶；往下拖回来，Hero 再出来。
            //   旧 131pt 下限（Hero 内上下内边距 20+20 + 顶行 30 + 底行
            //   歌名行高 titleSize×1.25 + 间距 8 + 副标题行高 20 =
            //   130.5→131）已删：它是面板滑不到顶部的拦路石，拖到底 Hero
            //   还剩 131pt，面板顶永远到不了顶部。Hero 高为 0 时
            //   HeroCardView 自身的 clipShape 把内容裁成 0 高、不溢出；
            //   只收卡片、不停播（播放钮在卡片里，收起来就看不见，
            //   播放在后台继续）。
            let titleSize: CGFloat = 26
            let minHeroH: CGFloat = 0
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
            //   r35-4：Hero 下限已是 0，不再保 Hero（歌名 + 播放钮可以整张
            //   收起来），面板取剩下的，不让区间倒挂（r28：667×375 档
            //   contentH 265 ≥ minHeroH 0 + minPanelH 129；
            //   max() 只是兜底，内容再矮 Hero 也能收到 0）。
            let maxHeroH = max(minHeroH, contentH - minPanelH)
            let minFrac = minHeroH / contentH
            let maxFrac = maxHeroH / contentH
            let storedFrac = isLandscape ? heroFractionLandscape : heroFractionPortrait
            let fraction = min(max(storedFrac, minFrac), maxFrac)
            let heroH = contentH * fraction
            // r28：面板高按内容封顶（壳版视频：面板约 336–407pt，本地音乐露在
            // 首屏；旧「两块拼满整屏」已作废）。内容高 = 内边距 20 + 条 48 +
            // 间距 8 + 内容区（每日内容：底座内边距 20 + 带 flatCard+53（r43-3：带高
            // flatCard+52+1，原 +58）+ 间距 6 + 提示行 27 = flatCard+106，再加 r30 栏头撤掉后
            // 多出的 30pt 余量）= flatCard + 217（标准档 407；
            // compact 397、large 426；公式不动，只改账）。
            // 横屏面板 140 本来就小于内容高，封顶不触发。拖大 Hero 后面板按
            // split 收缩（低于封顶），不受封顶影响；拖小 Hero 后面板停在封顶，
            // 余下是本地音乐，不留空。
            // r37-1：搜索歌单带已删（见文件头 r37-1 节）——搜索队列直接显示在
            // 每日推荐那排卡片里，不再另占一块带子，封顶不用再给它抬高；
            // r36 的 searchBeltExtraH（flatCard + 198）已删，封顶回到
            // flatCard + 217。r43-3：带高改成 flatCard + 53（两行字 52 + 点中上抬
            // 顶空 1），内容总高 flatCard + 212 ≤ 封顶，公式不动；r43-1：横屏模型
            // flatCard 改 158，内容 370 ≤ 封顶 426，封顶仍是上界、不脱节，公式不动。
            let panelContentH: CGFloat = flatCard + 217
            // r44（第 4 件）：横屏面板铺满全屏——collapseT 随 Hero 收缩坍缩顶栏
            // 与两处间隙：heroH ≥ maxHeroH/2（88pt）时为 0（布局与现况像素一致），
            // heroH → 0 时 → 1（顶栏高 64→0、gapTop 26→0、gapMid 20→0），
            // 面板高改走「屏高 − 坍缩后顶栏/间隙/Hero」不再被 contentH = 292 封顶，
            // heroH = 0 时面板 = 整屏 402pt；竖屏 collapseT 恒 0，走原值。
            // 坍缩段面板增速约 2.25 倍（Hero 收 1pt 面板长约 2.25pt），手柄仍 1:1 跟手，
            // 见交回。
            let collapseT: CGFloat = isLandscape ? max(0, 1 - heroH / (maxHeroH / 2)) : 0
            let topBarHLive: CGFloat = topBarH * (1 - collapseT)
            let gapTopLive: CGFloat = gapTop * (1 - collapseT)
            let gapMidLive: CGFloat = gapMid * (1 - collapseT)
            let panelH = isLandscape
                ? outer.size.height - (topBarHLive + gapTopLive + heroH + gapMidLive)
                : min(contentH - heroH, panelContentH)
            let blockW = outer.size.width - 32
            // r44（第 2 件）：横屏首页全宽出血——fullW = 整屏宽（100% 屏宽，
            // outer.size.width + 左右安全区），bleed = 安全区 + 16（卡边旧在屏边
            // 75pt 处，卡内边距加 bleed 后内容屏上位置不动）；竖屏为 0，走原值。
            let fullW = outer.size.width + outer.safeAreaInsets.leading + outer.safeAreaInsets.trailing
            let bleedL: CGFloat = isLandscape ? outer.safeAreaInsets.leading + 16 : 0
            let bleedT: CGFloat = isLandscape ? outer.safeAreaInsets.trailing + 16 : 0
            VStack(spacing: 0) {
                topBar(topPad: topPad, leadingPad: isLandscape ? outer.safeAreaInsets.leading + 16 : 16)
                    // r44（第 4 件）：横屏 Hero 收起时顶栏随 collapseT 坍缩渐隐
                    // （高 64→0，下缘裁切；竖屏 collapseT = 0，高 64 不动）。
                    // r46-2：第 2 件——框高 = topPad + topBarHLive：顶栏视图本身
                    // 高 topPad(31) + 64 = 95pt（topBar() 的 .padding(.top, topPad)
                    // 在内），只框 64pt 会把齿轮/搜索/品牌下半 31pt 裁掉
                    // （竖屏实拍暗像素在 63.7pt 断掉）；横屏 topPad=0，框高不变，
                    // collapse 64→0 保持。
                    .frame(height: topPad + topBarHLive, alignment: .top)
                    .clipped()
                    .opacity(isLandscape ? 1 - collapseT : 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // r28：竖屏 Hero + 面板 + 本地音乐按壳版视频排
                        // （顶栏 95 + 间距 14 + Hero 152 + 间隙 27 + 面板 407，
                        // 本地音乐露在首屏；旧「两块拼满、本地音乐不露首屏」
                        // 已作废，见文件头 r28 节）。
                        VStack(alignment: .leading, spacing: gapMidLive) { // r44（第 4 件）：间隙随 collapseT 坍缩；竖屏 = gapMid 不动
                            HeroCardView(
                                width: isLandscape ? fullW : blockW, // r44（第 2 件）：横屏全宽出血；竖屏 blockW 不动
                                viewHeight: outer.size.height,
                                height: heroH,
                                titleSize: titleSize,
                                // r45-fix：参数顺序必须跟 HeroCardView 的声明顺序一致
                                // （width/viewHeight/height/titleSize/bleedLeading/
                                // bleedTrailing/viewModel；memberwise init 按声明
                                // 顺序传参）。上一轮加 bleed 参数时把 viewModel 写在
                                // 了 bleed 前面，三轮构建到这里才报
                                // "argument 'bleedLeading' must precede 'viewModel'"——
                                // 上一轮按新流程没单独编译过，这处一直没被编到。
                                bleedLeading: bleedL, // r44（第 2 件）：卡内边距加 bleed，内容屏上位置不动
                                bleedTrailing: bleedT,
                                viewModel: viewModel
                            )
                            .padding(.horizontal, isLandscape ? 0 : 16) // r44（第 2 件）：横屏外边距 0（全出血）；竖屏 16 不动

                            // 铺色面板（壳版 `#hall-plat`）：平台条 → 来源内容
                            // （每日推荐 = 环/跑马带，其余来源 = rail 卡片跑马带），
                            // 同一块圆角面板里，顺序与壳版 bar → marquee 一致。
                            // 圆角 22、内边距 10（壳版 `.hall-plat` / plat-face）；
                            // 底色 = 当前平台品牌色 10% 淡 tint（壳版是平台色满铺，
                            // 原生浅色卡片 + 墨字只能淡 tint 近似，见文件头）。
                            // r21 起环的平面态就是每日跑马带，HomeView 不再单独挂
                            // DailyMarqueeView（两处并存会叠两条一样的带）。
                            dailyPanel(
                                width: isLandscape ? fullW : blockW, // r44（第 2 件）：横屏全宽出血；竖屏 blockW 不动
                                bleedLeading: bleedL, // r44（第 2 件）：面板内边距加 bleed，内容屏上位置不动
                                bleedTrailing: bleedT,
                                height: panelH,
                                isLandscape: isLandscape,
                                tier: tier,
                                screenWidth: outer.size.width, // r39-5：第 5 件——实测屏宽，环几何按它算
                                screenHeight: outer.size.height // r43-1：第 1 件——实测屏高，判横竖屏用
                            )
                            // r22l 编译修：231 行 tier 类型错导致这行
                            // dailyPanel 调用的结果类型推不出来，`.horizontal`
                            // 跟着报「cannot infer contextual base」——
                            // 是 231 行的级联，不是这行本身写错；写明
                            // Edge.Set 后即使类型再出问题也不会连带误报，
                            // 布局与数值与原来完全一致。
                            .padding(Edge.Set.horizontal, isLandscape ? 0 : 16) // r44（第 2 件）：横屏外边距 0（全出血）；竖屏 16 不动
                        }
                        .padding(.top, gapTopLive) // r44（第 4 件）：顶间距随 collapseT 坍缩；竖屏 = gapTop 不动
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
                                .frame(width: isLandscape ? fullW : blockW, height: 28) // r44（第 2 件）：横屏与两卡同宽（全宽）；竖屏 blockW 不动
                                // r44（第 4 件）：手柄跟 live 间隙走；横屏全屏时夹到 ≥0
                                // （手柄贴屏顶 0–28pt 可抓，与面板顶重叠 28pt，见交回）。
                                .offset(y: max(0, gapTopLive + heroH + gapMidLive / 2 - 14))
                                // r45-fix：手势与微调动作都抽到 body 上方的函数里，
                                // body 里只剩引用，不再整条大表达式一起查。
                                .gesture(dividerDragGesture(heroH: heroH, minHeroH: minHeroH, maxHeroH: maxHeroH, contentH: contentH, isLandscape: isLandscape))
                                .accessibilityLabel("调整 Hero 与面板高度")
                                .accessibilityHint("上下拖动改变两块高度，松手即停")
                                .accessibilityAdjustableAction(dividerAdjustAction(fraction: fraction, minFrac: minFrac, maxFrac: maxFrac, isLandscape: isLandscape))
                        }

                        // 面板之下：下载管理卡 + 本地音乐区（r28：竖屏露在首屏，不再是
                        // 「下滑才看到」；见文件头 r28 节）。
                        // r33-download-entry：下载管理卡从 LocalMusicSectionView
                        // 搬到这里、本地音乐区块的正上方（紧贴本地音乐，还是
                        // 「本地音乐附近」），原来在 LocalMusicSectionView 最末、
                        // 首屏之外、滑到底才看得见；现在一眼见。卡放在
                        // `if localMusicShown` 之外，本地音乐开关关了它也一直在。
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
                        // r44（第 2 件）：横屏 ScrollView 扩到整屏宽后，本地音乐
                        // 加左右安全区边距（屏上 59–815pt 位置不动）；竖屏不加。
                        .padding(.leading, isLandscape ? outer.safeAreaInsets.leading : 0)
                        .padding(.trailing, isLandscape ? outer.safeAreaInsets.trailing : 0)
                        // r35-5：底部留白固定 `homeBottomPad` = 50（16 净空 +
                        // 34 Home Indicator，底部安全区已忽略，见 ignoresSafeArea；
                        // 滑到底时本地音乐导入钮离 Home Indicator 还有 16pt 净空，
                        // 下面不再多出一大片空白）。r31 的重算已删（见文件头 r35 节）。
                        .padding(.bottom, homeBottomPad)
                    }
                }
                // r24：拖分界手柄时外层整页 ScrollView 不许跟着滚
                // （dividerDragging 只在竖向拖动里置 true，松手清掉；
                // minOS 16.2 可用，本项目已有 LyricsPanelView 同款用法）。
                .scrollDisabled(dividerDragging)
                // r48-7：第 7 件——首页下拉刷新：向下拉、松手后重新拉取当前
                // 模式的内容（HomeViewModel.refreshCurrentSource，走现有
                // 取数链路 force 重拉；ListeningRankView 同款 .refreshable
                // 用法）。竖屏横屏共用这一个外层 ScrollView，两向都能用；
                // 不丢在播的歌、不换模式、不重置带子位置（见 refreshCurrentSource）。
                .refreshable { await viewModel.refreshCurrentSource() }
                // r44（第 2 件）：横屏 ScrollView 左右忽略安全区、扩到整屏宽，
                // Hero/面板才能出血到屏边；竖屏不扩。顶栏是 ScrollView 的兄弟，
                // 不受影响。真机验证见交回。
                .ignoresSafeArea(edges: isLandscape ? [.leading, .trailing] : [])
                // r35-5：r31 的底部留白重算已删（见文件头 r35 节）：底边距
                // 固定 50，不再量内容实高补行程；面板顶到顶部的路改走
                // 分界手柄（r35-4）。
                // r31-imagebg：滚动区底色改透明——背景层在 GeometryReader
                // 的 .background 里（HomeBackgroundView），滚动内容之上
                // 不再盖一层纸色，图片/视频背景才能露出来；默认模式下
                // HomeBackgroundView 自己就是纸色，视觉与原来一致。
                .background(Color.clear)
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
            // r44（第 5 件）：排行榜/精选等用的 railRingModel 与榜单详情用的
            // rankSongsRingModel 原来没有覆盖层——开环后没有任何 RingTouchView
            // 承接换手拖动：松手后 ringDragging = false，新手指落在平面带上时
            // stripTouchBegan 因 phase != .closed 直接返回、ringDragMoved 又被
            // ringDragging 守卫挡住，环冻住不动，只能等 1 秒自动收回再重开，
            // 这就是「转着转着就停了、滑不动了」。与每日环同款，各补一个覆盖层；
            // 同一时间只显示一个来源，同一时刻最多一个环处于展开态，不叠加。
            .overlay {
                if railRingModel.ringPhase != .closed {
                    HomeRingOverlayView(model: railRingModel)
                }
            }
            .overlay {
                if rankSongsRingModel.ringPhase != .closed {
                    HomeRingOverlayView(model: rankSongsRingModel)
                }
            }
            // r31-imagebg：首页/大厅背景层（默认 = 原来的纸色；静态图片 /
            // 动态壁纸见 BackgroundView.swift）；在全部内容之下，不盖内容。
            .background { HomeBackgroundView() }
        }
        // 模板 v2：顶栏整行按屏顶定位（品牌中心竖屏 63pt、横屏 32pt），
        // 不按安全区顶；忽略顶部与底部安全区后
        // GeometryReader 原点 = 屏顶、size = 整屏（390×844 档 viewHeight
        // 从 781 变 874，Hero 高随之变，见驱动 2b；sizeTier 只看宽度，
        // 不受影响；"liziHome" 坐标系与环覆盖层同系，相对位置不变）。
        // 底部留白由内容自己留（`homeBottomPad` 固定 50 = 16 净空 +
        // 34 Home Indicator，r35-5 起不再重算补行程），不靠系统安全区。
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
        .onChange(of: playback.queue.map(\.queueId)) { _ in
            // r47-4：点播（setQueue 重建队列，queueId 全是新 UUID）后面板
            // 切到「正在播放」，不再留在今日推荐；已在正在播放时
            // selectSource 直接 return。自动切歌不走 setQueue、不重建队列，
            // 不触发——正在浏览别的模式/已打开的歌单详情时不被拽回来。
            if !playback.queue.isEmpty {
                viewModel.selectSource(.nowPlaying)
            }
        }
        // r47-4：从暂停恢复播（队列与当前曲目都不变时）也切到「正在播放」；
        // 只在 false→true 时触发，暂停/停播不切回去（菜单顺序另由
        // menuOrderFor(isPlaying:) 管；打断后自动恢复也走这里，见 D7）。
        .onChange(of: playback.isPlaying) { playing in
            if playing {
                viewModel.selectSource(.nowPlaying)
            }
        }
    }

    /// 每日推荐铺色面板（壳版 `#hall-plat` 内容；r28：底色是专辑取色渐变，
    /// 见 `panelTone` 与文件尾 `AlbumTone`）：
    /// 圆角 22、内边距 10、底色 tone-a→tone-b→tone-c 对角渐变；
    /// 环内容超出面板窗的部分从底边裁掉（横屏面板 140 比内容矮得多；
    /// 模板里面板封面本来就是齐底边裁断的）。顺序：条 → 内容（r30：栏头已删，条之下直接是
    /// 一次一栏的内容区；r28 分页器的栏头/圆点/上下钮/竖滑切栏全撤，
    /// 来源改点条标题弹小菜单切，见 `sourceMenuOverlay`）。
    /// r23h：平台条钉在面板顶、不进竖滑 ScrollView——
    /// 面板是定高窗、内容比窗高，放歌后环内容一换（每日 → 队列）或手指
    /// 在面板里竖滑，ScrollView 的偏移会把条顶出窗外、再也滑
    /// 不回来（07:09 真机：条 + chips 全没了、环还在）；钉在外面后偏移
    /// 再怎么变也顶不走它。
    /// 真机风险：面板内竖滑与环的横向拖动展开手势竞争（r40：上滑开环已删，
    /// 改回 r24 横向拖动开环）——环的展开用 UIKit
    /// pan recognizer（见 HomeCoverRingView，r21 教训后不再用 SwiftUI
    /// DragGesture），它与外层 ScrollView 竖滑共存；现在多了一层面板内
    /// ScrollView，展开手势是否仍优先，要真机验（见清单 D19）。
    /// r40：环的触发改回 r24（横向拖动开环，竖向拖动交还 ScrollView；
    /// r39-5 的上滑开环 + 横向手滚跑马带作废）。r30：面板内容区竖滑不再切栏
    /// （分页器已撤），竖滑归外层 ScrollView 滚整页、横向拖动开环、
    /// 点按播歌/进详情；横屏面板只有约 140 高，条占掉大半后 rail 栏
    /// 只剩约一行的位置，「查看全部」进整页看全量，
    /// 见 `RailSourceListView`（原 `HomeRailPageView`）的文件头注释。
    /// r31-landscape：r30 这句「竖滑归外层 ScrollView」当时并没做到——
    /// `dailyRingContent` 里还包着一层竖向 ScrollView（面板内竖滑），
    /// 它才是首页滑不动的根因（见文件头 r31 节），本轮已拆掉；
    /// r23h 上面那段「多了一层面板内 ScrollView，展开手势是否仍优先」
    /// 也随之作废：面板里不再有第二层 ScrollView 可争。
    /// r22l 编译修：真类型名是 PlayerTokens.PlayerSizeTier
    ///（PlayerTokens.swift 里 `enum PlayerSizeTier`，r20 约定名），
    /// 之前写的 SizeTier 不存在。
    private func dailyPanel(
        width: CGFloat,
        bleedLeading: CGFloat = 0, // r44（第 2 件）：横屏全宽出血时面板内左/右边距补偿（安全区 + 16，默认 0）
        bleedTrailing: CGFloat = 0, // r44（第 2 件）：同上
        height: CGFloat,
        isLandscape: Bool,
        tier: PlayerTokens.PlayerSizeTier,
        screenWidth: CGFloat, // r39-5：第 5 件——实测屏宽，见 sourceContent
        screenHeight: CGFloat // r43-1：第 1 件——实测屏高，判横竖屏用
    ) -> some View {
        // r23h：条钉在面板顶，见本函数头注释。
        VStack(spacing: 8) {
            // r37-1（顶栏常驻）：顶栏就是面板的第一行，上面不再压任何块——
            // r35-3 的置顶行（nowPlayingPinBlock，带歌名/歌手 + 播放/暂停钮）
            // 与搜索歌单带（searchQueueBlock）已删：置顶行与「卡片只放封面、
            // 没有暂停键」冲突，两块又占着面板顶、Hero 拖大后面板缩小时会把
            // 顶栏顶出定高窗（看不见、点不到）；搜索队列不再另占一块带子，
            // r38-1：也不再进每日推荐那排卡片，改由「正在播放」模式承载
            // （见 nowPlayingRingContent）。
            // r36-2：排行榜块已拆（r35-10 的 rankBlock 在此，搜歌块在上、
            // 榜单块在下；现改成来源菜单里的一项，见 sourceContent 的
            // .rank 分支 + rankSourceContent），面板里不再留榜单块。
            // r28 tone-aware：平台条标题/返回键/选中圈跟专辑取色深场走白字、浅场走墨色。
            // r30：点标题弹来源小菜单（壳版 #hall-src-menu 思路）。
            // r37-1：顶栏不再在榜单详情态隐藏——r36 v4 的
            // `if selectedRankBoard == nil` 守卫已删（详情态顶栏只留榜单名 +
            // 返回 + 搜索是旧稿图的做法，新定稿要求顶栏和菜单一直在，随时能
            // 点回今日推荐或用户自建歌单）；榜单详情自己的顶行原样保留。
            PlatformStripView(
                viewModel: viewModel,
                isDark: panelTone.isDark,
                onSourceMenuTap: { sourceMenuShown = true },
                onBackTap: {
                    // r39-6：第 6 件——面板顶栏右端返回键：回到上一层，只用现有返回逻辑，
                    // 不另起新逻辑。榜单详情 → 回榜单列表（rankDetailContent「‹ 榜单」同款）；
                    // 面板内打开的歌单/专辑 → 回该来源列表（openedView「返回…」同款，
                    // viewModel.closeOpened()）；子模式（正在播放/精选/喜欢/我的歌单/
                    // 电台/排行榜）→ 回今日推荐（来源菜单点「每日推荐」同款，
                    // selectSource(.daily)，它自己先 closeOpened()）；已在今日推荐
                    // 顶层时无上一层，不做事。
                    if selectedRankBoard != nil {
                        selectedRankBoard = nil
                        rankDetailTracks = []
                    } else if viewModel.isOpenedCollection {
                        viewModel.closeOpened()
                    } else if viewModel.selectedSource != .daily {
                        viewModel.selectSource(.daily)
                    }
                }
            )
            // r30 来源内容：每日推荐 = 环/跑马带，其余 4 栏 = rail 卡片跑马带
            // + 排行榜面板（r36-2，见 sourceContent 的 .rank 分支）
            // （原 HomeRailPageView，原样搬进本文件 RailSourceListView；
            // r31：列表行改成与每日带同款的横向卡片跑马带，见 RailSourceListView
            // 文件头注释）。
            // 来源切换不走翻页手势：菜单点选即切；面板内竖滑归外层
            // ScrollView 滚整页，横向拖动开环（r40，改回 r24）。
            sourceContent(tier: tier, screenWidth: screenWidth, screenHeight: screenHeight)
                .id(viewModel.selectedSource)
                .transition(.opacity)
                // r36 v4：切来源 / 切平台时退出榜单详情（榜单是按平台的，
                // 旧榜的歌不能留在新平台的面板里）。
                .onChange(of: viewModel.selectedSource) { _ in
                    selectedRankBoard = nil
                    rankDetailTracks = []
                }
                .onChange(of: viewModel.selectedPlatform) { _ in
                    selectedRankBoard = nil
                    rankDetailTracks = []
                }
        }
        // r44（第 2 件）：横屏全宽出血时内边距左右加 bleed（内容屏上位置不动），
        // 上下仍 10；竖屏 bleed = 0，走原值。
        .padding(.vertical, 10)
        .padding(.leading, 10 + bleedLeading)
        .padding(.trailing, 10 + bleedTrailing)
        // r31-landscape：顶对齐——环内容比横屏面板窗高（内容 302 >
        // 窗口 46.5），frame 默认居中会把平台条顶出窗外；顶对齐后
        // 条钉在面板顶、超出的环内容从底边裁掉（模板原意「齐底边裁断」，
        // 由下面 clipShape 裁；dailyRingContent 的内层竖滑已拆，
        // 竖滑归外层整页，见文件头 r31 节）。
        .frame(width: width, height: height, alignment: .top)
        .background(
            LinearGradient(
                colors: [panelTone.a, panelTone.b, panelTone.c],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        // r44（第 2 件）：横屏全宽出血时圆角 22→0（否则圆角缺口破坏全出血）；竖屏不动。
        .clipShape(RoundedRectangle(cornerRadius: (bleedLeading > 0 || bleedTrailing > 0) ? 0 : LiziTokens.radius22))
        // r30 来源小菜单浮层（壳版 #hall-src-menu 思路：挂在标题下、
        // 可溢出面板边缘；点菜单外任意处关，选来源后关）。
        // overlay 挂在 clipShape 之后，不被圆角裁掉；菜单卡本身是浅色卡、
        // 与面板取色无关，任何 tone 下都可读。
        .overlay(alignment: .topLeading) {
            if sourceMenuShown {
                sourceMenuOverlay(bleedLeading: bleedLeading)
            }
        }
    }

    /// r36-2：排行榜来源面板（菜单点「排行榜」切到这里，见 sourceContent
    /// 的 .rank 分支；r35-10 的 rankBlock 在 dailyPanel 里，现整块搬过来）：
    /// 当前平台的榜单列表——横向 ScrollView 全排出来（r37-5：旧跑马带一屏
    /// 只装得下约 1.8 张，见 rankBoardListContent；卡片就是截图里那种榜单卡：
    /// 榜单名 + 封面/占位，r36：卡宽改成与首页环平面带同档
    /// （compact 180 / standard 190 / large 209，见 body 里 flatCard
    /// 同款公式）；点卡选中该榜单，面板换成
    /// 该榜单的全部歌（r36 v4，见 rankDetailContent，不再跳独立详情页）。
    /// 标题行不另画——平台条上已显示来源名「排行榜」。
    /// 没榜的平台（波点/汽水/Apple Music）只画诚实文案
    /// （viewModel.rankEmptyReason），不发请求、不隐藏整块；正在加载
    /// 时 250ms 后才亮 spinner（viewModel.rankSpinnerVisible），
    /// 250ms 内是空白占位、不闪；旧榜在加载中先留着（loadRankBoards
    /// 只在回来后才换 rankBoards）。
    private func rankSourceContent(isDark: Bool, tier: PlayerTokens.PlayerSizeTier, screenWidth: CGFloat, screenHeight: CGFloat) -> some View { // r39-5：第 5 件——实测屏宽透传给环；r43-1：屏高同路透传
        Group {
            if let board = selectedRankBoard {
                rankDetailContent(board: board, isDark: isDark, tier: tier, screenWidth: screenWidth, screenHeight: screenHeight)
            } else {
                rankBoardListContent(isDark: isDark, tier: tier, screenWidth: screenWidth, screenHeight: screenHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// r36 v4（用户 21:45 批「对就是这样」，稿图 lizi-chart-detail-mockup.png）：
    /// 榜单详情面板——榜单里的全部歌（100/1000 首）一张一张排到首页面板里，
    /// 像今日推荐那样横向轮播（HomeCoverRingView，独立 rankSongsRingModel）；
    /// 每张卡封面-only（r37-1：图到后只显封面、图未到先显歌名占位；
    /// 3D 环展开态的环卡按套壳版带歌名——00:42:43 纠正：1:1 复刻只限 3D 环卡），
    /// 不带排名数字（21:43）、不显示多少首（21:44）、
    /// 不加任何提示文字（21:44，hideEntryHint）；
    /// 点卡播歌（环自带 setQueue 整队从该下标起播）。
    /// 面板顶栏只留三样：榜单名（左）+ 返回「‹ 榜单」+ 搜索（右）。
    /// 面板底色是专辑取色（dailyPanel 的 panelTone，稿图里的绿就是
    /// 当前那首绿封面的取色，与 Hero 同款——不用另算）。
    /// 取数：playlistDetail(isRank: true) 全量（网易单次全量、QQ 上限 300、
    /// 酷狗 10 页×100、酷我 10 页×200；见 NativeBridge.playlistAllTracks）。
    /// 加载中只亮 spinner（无文字）；空榜（拉不到/0 首）给诚实空态一行，
    /// 不是操作提示。
    private func rankDetailContent(board: RankBoard, isDark: Bool, tier: PlayerTokens.PlayerSizeTier, screenWidth: CGFloat, screenHeight: CGFloat) -> some View { // r39-5：第 5 件——实测屏宽透传给环；r43-1：屏高同路透传
        VStack(alignment: .leading, spacing: 8) {
            // v4 顶栏：左榜单名，右「‹ 榜单」返回 + 放大镜搜索。
            HStack(spacing: 12) {
                Text(board.name)
                    .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                    .foregroundColor(isDark ? .white : LiziTokens.ink)
                    .lineLimit(1)
                Spacer()
                Button(action: {
                    selectedRankBoard = nil
                    rankDetailTracks = []
                }) {
                    Text("‹ 榜单")
                        .font(.liziBody(size: LiziTokens.size14))
                        .foregroundColor(isDark ? .white.opacity(0.75) : LiziTokens.ink3)
                }
                .accessibilityLabel("返回榜单列表")
                Button(action: { nav.show(.search) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isDark ? .white : LiziTokens.ink)
                }
                .accessibilityLabel("搜索")
            }
            if !rankDetailTracks.isEmpty {
                HomeCoverRingView(
                    model: rankSongsRingModel,
                    dailyTracks: rankDetailTracks,
                    marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                    tier: tier,
                    panelIsDark: isDark,
                    coverOnly: true,
                    hideEntryHint: true,
                    screenWidth: screenWidth, // r39-5：第 5 件
                    screenHeight: screenHeight // r43-1：第 1 件（成员初始化器顺序：screenHeight 是末位存储属性，调用点必须放最后）
                )
            } else if rankDetailLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 20)
            } else {
                Text("该榜单暂无曲目")
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(isDark ? .white.opacity(0.62) : LiziTokens.ink3)
            }
        }
        .task(id: board.id) {
            // 榜单一切换就重拉全量；旧任务取消、旧结果不回写（id 守卫）。
            let platform = viewModel.selectedPlatform
            let boardId = board.id
            let pl = await NativeBridge.playlistDetail(platform: platform, id: boardId, isRank: true)
            guard selectedRankBoard?.id == boardId else { return }
            rankDetailTracks = pl.tracks
            rankDetailLoading = false
        }
    }

    /// 榜单目录（未点进某张榜单时）：当前平台的榜单列表——接 3D 环
    /// （r43-2：第 2 件，与 rail 四栏同一套 `HomeCoverRingView` + 共用
    /// railRingModel；榜单卡点按仍是选中榜单进详情，详情已有环）。
    /// r37-5 的成果保住了：环靠拖动旋转能翻到全部榜单——环槽位取模
    /// （`visibleSlots` 的 mod(anchorIndex + s, n)）不截断条目，
    /// cap（竖屏约 7、横屏约 11）只定槽距、不定条目上限；网易 65 个、
    /// 酷狗 56 个、QQ 30 个榜单全靠转环翻到，横向 ScrollView 随之撤掉。
    /// 没榜的平台只画诚实文案，不发请求。
    /// r37-5（排行榜一次只露 2 张卡）：根因在 UI 不在取数——
    /// NativeBridge.rankBoards 回全量榜单（网易 65 个、QQ 30 个、酷狗 56 个、
    /// 酷我 bangMenu 全量，无任何 prefix(2)/截断），旧写法却把榜单塞进
    /// RailMarqueeView 跑马带：面板宽约 358pt、卡宽 190pt，一屏只装得下
    /// 约 1.8 张，剩下全被 .clipped() 裁掉、只能等带子自己滚过来；带子
    /// 一停（dwell/拖动旗）用户就只看到头 2 张。改法：榜单目录改成横向
    /// ScrollView，一张一张全排出来，用户自己左右滑看全量，不再依赖
    /// 跑马带；卡片仍是 RailMarqueeCardView（r39-4：卡下两行字，榜单名 +
    /// 副信息；点卡进详情的路由不动），驱动不再参与榜单目录（共享 railMarqueeDriver 的
    /// setWidth stale 问题随之绕开）。
    /// r43-2：第 2 件——ScrollView 撤掉的理由：环的平面带本身就是横向带
    /// （24px/s 自动走 + 拖动转环），榜单全量都在环上、不再只露头 2 张；
    /// 榜单目录与 rail 四栏共用 railRingModel（同一时间只显示一个来源）。
    private func rankBoardListContent(isDark: Bool, tier: PlayerTokens.PlayerSizeTier, screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.rankBoards.isEmpty {
                HomeCoverRingView(
                    model: railRingModel,
                    marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                    tier: tier,
                    panelIsDark: isDark,
                    coverOnly: true,
                    screenWidth: screenWidth, // r39-5：第 5 件——实测屏宽，环几何按它算
                    screenHeight: screenHeight, // r43-1：第 1 件——实测屏高，判横竖屏用
                    cards: rankCards.map(\.ringCard) // r43-2：第 2 件（成员初始化器顺序：cards 是末位存储属性，调用点必须放最后；run 45011589996 编译修）
                )
            } else if viewModel.rankSpinnerVisible {
                // 250ms 后仍在加载：spinner（与 rail 各栏 loadingView 同款
                // 尺寸，见 RailSourceListView）。
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(height: 20)
            } else if let reason = viewModel.rankEmptyReason {
                Text(reason)
                    .font(.liziBody(size: LiziTokens.size13))
                    .foregroundColor(isDark ? .white.opacity(0.62) : LiziTokens.ink3)
                    .lineLimit(2)
            } else {
                // 正在加载但 250ms 未到：空白占位，不闪 spinner、不闪空态。
                Color.clear.frame(height: 20)
            }
        }
    }

    /// 排行榜带的卡片：榜单目录原样映射；点卡选中该榜单——面板换成
    /// 该榜单的全部歌（r36 v4，21:45 定稿：榜单详情就在首页面板里，
    /// 不再跳独立详情页；点卡播歌走面板里的轮播）。
    /// 旧路由（nav.show(.playlist(isRank: true))）已删；独立详情页
    /// PlaylistDetailView 的 isRank 轮播分支留着（深链等其他入口
    /// 仍可进，显示规则与面板一致：无排名数字、无总数、无提示）。
    private var rankCards: [RailMarqueeCard] {
        viewModel.rankBoards.map { board in
            RailMarqueeCard(
                id: board.id,
                coverURL: board.coverURL,
                title: board.name,
                subtitle: board.trackCount > 0 ? "共 \(board.trackCount) 首" : "",
                onTap: {
                    selectedRankBoard = board
                    rankDetailTracks = []
                    rankDetailLoading = true
                }
            )
        }
    }

    /// r30 来源内容：一次只显示一个来源。每日推荐走修好的环/跑马带，
    /// 其余 4 栏走 rail 卡片跑马带（取数见 `HomeViewModel.loadRailPage`，
    /// 首次访问拉取、之后缓存，喜欢栏每次切回都重拉）；排行榜（r36-2）
    /// 走 rankSourceContent（榜单带，取数与每日推荐同批起、切过去直接画）；
    /// 正在播放（r38-1）走 nowPlayingRingContent（直播队列，不取数）。
    @ViewBuilder
    private func sourceContent(
        tier: PlayerTokens.PlayerSizeTier,
        screenWidth: CGFloat, // r39-5：第 5 件——实测屏宽，见 dailyPanel
        screenHeight: CGFloat // r43-1：第 1 件——实测屏高，判横竖屏用
    ) -> some View {
        switch viewModel.selectedSource {
        case .daily:
            dailyRingContent(tier: tier, screenWidth: screenWidth, screenHeight: screenHeight)
        case .nowPlaying: // r38-1
            nowPlayingRingContent(tier: tier, screenWidth: screenWidth, screenHeight: screenHeight)
        case .rank:
            rankSourceContent(isDark: panelTone.isDark, tier: tier, screenWidth: screenWidth, screenHeight: screenHeight)
        case .featured, .liked, .created, .radio:
            // r31：卡宽与环平面带同档（compact 180 / standard 190 / large 209，
            // 见 HomeCoverRingModel.flatCard），7 个来源卡片同尺寸；
            // isDark 跟面板取色走；跑马带驱动归 HomeView 所有（切来源不重建）。
            // r43-2：第 2 件——4 栏改走 3D 环（HomeCoverRingView + railRingModel，
            // 见 RailSourceListView.entriesView/openedView）；tier 与屏宽/高
            // 同路透传给环（r43-1 的 screenHeight 在末位）。
            RailSourceListView(
                viewModel: viewModel,
                cardWidth: tier == .compact ? 180 : tier == .standard ? 190 : 209,
                isDark: panelTone.isDark,
                marqueeDriver: railMarqueeDriver,
                tier: tier,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                ringModel: railRingModel
            )
        }
    }

    /// r30 来源小菜单浮层：标题下 7 行来源（每日推荐 / 正在播放 / 精选 /
    /// 喜欢的歌曲 / 我的歌单 / 电台 / 排行榜；r31 起「用户收藏」已删、数据并进
    /// 「我喜欢」，「用户创建的歌单」改名「我的歌单」；r36-2 加「排行榜」；
    /// r38-1 加「正在播放」，排第 2，顺序见 `HomeRailPage.menuOrder`），
    /// 当前来源打勾；点菜单外任意处只关菜单。壳版 `#hall-src-menu`（public/index.html
    /// 约 250 行 + hall/option-wheel.js）同款思路：浮层挂在标题下、
    /// 内容由来源列表填、点选切换；原生不用滚轮，用点选列表。
    // r44（第 2 件）：来源菜单改成函数、接 bleedLeading——面板横屏变宽后
    // 菜单 leading 同步加 bleed，位置不动（菜单在 body 的 GeometryReader 之外，
    // 读不到 body 里的 bleedL，改由 dailyPanel 传进来）。
    private func sourceMenuOverlay(bleedLeading: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // 点菜单外关：整块面板大小的透明层（菜单卡在它上面，
            // 卡上的点按走行按钮，不落到这里）。
            Color.black.opacity(0.001)
                .onTapGesture { sourceMenuShown = false }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(HomeRailPage.menuOrderFor(isPlaying: playback.isPlaying), id: \.rawValue) { page in // r47-4：菜单按播/停排（在播「正在播放」第一排，不在播恢复正常顺序；不写「置顶」二字）
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
            // r44（第 2 件）：横屏出血时 leading 加 bleedLeading（面板变宽后
            // 菜单位置不动）；竖屏 bleedLeading = 0，走原值。
            .padding(.leading, 10 + bleedLeading)
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
    /// r31-landscape：这里原来包了一层竖向 ScrollView（面板内竖滑），
    /// 已拆掉——那层就是首页滑不动的根因（见文件头 r31 节）：
    /// 同向嵌套 ScrollView，面板里的竖向拖动全被它吃掉，外层滚不到；
    /// 竖屏它根本滚不动（内容 283 < 窗口 331），横屏它先滚完自己的
    /// 255.5pt 才停，外层一次都轮不到。拆掉后面板内容超出窗的部分
    /// 由面板圆角裁掉（模板原意「齐底边裁断」），竖滑归外层整页。
    /// r37-1：卡片封面-only（`coverOnly: true`，见 HomeCoverRingView），
    /// 点卡播歌、跑马带、3D 环开环一律不动。
    /// r39-4：第 4 件起 coverOnly 不再藏卡下两行字——平面带卡下恢复歌名 +
    /// 演唱者（`FlatRingCard`，只加这两个，不加专辑名），点中的卡整体上抬 1pt（r43-3）。
    /// r38-1：每日推荐永远只显示 `viewModel.daily`——r37-1 的 searchQueue
    /// 覆盖已删：搜完点歌立起的队列不再挤占今日推荐那排卡片，改由菜单
    /// 「正在播放」模式承载（见 nowPlayingRingContent）；queueTitle 传 nil，
    /// 环本身、跑马带、3D 环、点卡播歌一律不动。
    private func dailyRingContent(
        tier: PlayerTokens.PlayerSizeTier,
        screenWidth: CGFloat, // r39-5：第 5 件——实测屏宽，见 dailyPanel
        screenHeight: CGFloat // r43-1：第 1 件——实测屏高，判横竖屏用
    ) -> some View {
        HomeCoverRingView(
            model: ringModel,
            dailyTracks: viewModel.daily.map { $0.track },
            isLoadingDaily: viewModel.isLoadingDaily,
            dailySpinnerVisible: viewModel.dailySpinnerVisible,
            dailyEmptyReason: viewModel.dailyEmptyReason,
            marqueeSpeed: viewModel.marqSpeedPxPerSecond,
            tier: tier,
            panelIsDark: panelTone.isDark,
            queueTitle: nil, // r38-1：每日推荐不带队列标题
            coverOnly: true,
            screenWidth: screenWidth, // r39-5：第 5 件
            screenHeight: screenHeight // r43-1：第 1 件（成员初始化器顺序：screenHeight 是末位存储属性，调用点必须放最后）
        )
    }

    /// r38-1：正在播放（菜单第 2 项，用户 2026-11-22 定稿）——当前播单整条
    /// 直播队列：搜完点歌立起的队列（queueTitle「搜索：词」）+ 下一首要播的
    /// 歌（playNext 插队进的也在队列里），正在播的 + 接下来要播的都在这里。
    /// 复用每日推荐同款 `HomeCoverRingView`（coverOnly: true、同一套跑马带/
    /// 3D 环、点卡播歌走环自带的 setQueue 逻辑），不取数、不另起历史表；
    /// isLoading/spinner 传 false；队列为空时给诚实空态（环的 emptyView
    /// 同款样式，见 HomeCoverRingView.emptyView）。
    private func nowPlayingRingContent(
        tier: PlayerTokens.PlayerSizeTier,
        screenWidth: CGFloat, // r39-5：第 5 件——实测屏宽，见 dailyPanel
        screenHeight: CGFloat // r43-1：第 1 件——实测屏高，判横竖屏用
    ) -> some View {
        HomeCoverRingView(
            model: ringModel,
            dailyTracks: playback.queue.map { $0.track },
            isLoadingDaily: false,
            dailySpinnerVisible: false,
            dailyEmptyReason: playback.queue.isEmpty ? "还没有正在播放的歌曲。" : nil,
            marqueeSpeed: viewModel.marqSpeedPxPerSecond,
            tier: tier,
            panelIsDark: panelTone.isDark,
            queueTitle: playback.queueTitle,
            coverOnly: true,
            screenWidth: screenWidth, // r39-5：第 5 件
            screenHeight: screenHeight // r43-1：第 1 件（成员初始化器顺序：screenHeight 是末位存储属性，调用点必须放最后）
        )
    }

    /// r31：面板里 4 个 rail 来源（精选 / 喜欢的歌曲 /
    /// 我的歌单 / 电台；「用户收藏」已删、数据并进「我喜欢」，
    /// 「用户创建的歌单」改名「我的歌单」）改成与每日推荐同款的横向卡片跑马带
    /// （`RailMarqueeView`），不再是竖向列表。r30 的列表行（曲目 =
    /// TrackRowView 56pt 行，歌单/电台 = 56pt 横行）已删：
    /// r43-2：第 2 件——4 栏的跑马带改成与每日推荐同一套 3D 环
    /// （`HomeCoverRingView` + 共用 railRingModel，见 entriesView/openedView；
    /// 平面带 + 3D 环 + 手势链全复用环的，不另写一套；`RailMarqueeView` /
    /// `RailMarqueeDriver` 原样留着不动，驱动留待环真机验证后另行退役）。
    /// - 曲目卡 = 封面 + 卡下两行字（r39-4：歌名 + 演唱者；环平面带 FlatRingCard
    ///   同款形状，卡宽与环同档），点一张播一首（setQueue 整份曲目）；
    /// - 歌单/专辑/电台卡 = 该集合本身（r39-4：卡下两行字，名字 + 副信息），
    ///   点一张进面板内集合曲目（r31：我的歌单 / 我喜欢里的歌单或专辑卡
    ///   点后不跳详情页，面板原地换成该集合的全部歌曲卡片，返回键回列表；
    ///   精选/电台里的歌单卡仍进歌单详情页），不显示成文字列表；
    /// - 分组说明卡（网易「我创建的歌单 / 我收藏的歌单」、Apple Music
    ///   「官方热门歌单（非本人收藏）」、本地星标说明）不是内容，
    ///   不进跑马带（壳版 marq__card--group 同款说明只在详情页出现）；
    /// - 跑马带在 5 栏里都一直自动向左滚（24px/s，与每日带一致），
    ///   切来源后接着滚（驱动归 HomeView 所有，不重建；内容换了只归一化
    ///   偏移，不归零、不重停，见 `RailMarqueeDriver.noteContentChanged`）。
    /// - 平台返回类型本来就不同（见 RailsBridge 文件头）：网易/QQ/波点精选=歌单、
    ///   酷狗/汽水精选=曲目、酷我精选=排行榜（歌单）；空态文案原样保留
    ///   （如「这一层没有歌曲」「这一层没有歌单」与各平台诚实原因）。
    ///
    /// 面板是定高窗：跑马带一排卡（卡高 = 卡宽 + 52，r39-4：卡下两行字，
    /// 与环平面带 flatHeight 的两行字同高）
    /// + 底部「查看全部」进 RailDetailView 整页（带子滚动看全量，
    /// 不再只放 3 条）；横屏面板只有约 140 高，栏头 + 条占掉
    /// 大半后 rail 栏只剩约一行的位置、其余裁断是模板原意，
    /// 与每日推荐横屏同款。
    /// 点卡行为与 RailDetailView 一致：曲目点播（setQueue 整份曲目，含分组卡
    /// 之后的全部曲目）、歌单卡在我的歌单 / 我喜欢里进面板内集合曲目
    /// （`viewModel.openPlaylist`，r31），其余来源进歌单详情页
    /// （.playlist 路由）、电台频道卡进电台整页（.rail radio；频道下钻在
    /// 详情页里点，面板不另做下钻层；波点电台本身就是曲目，点行直接播）。
    /// 专辑卡（r31：收藏的专辑在「我喜欢」里）点后进面板内专辑曲目
    /// （`viewModel.openAlbum`）。
    /// 加载/失败/空态走 RailDetailView 同款三态（文案由 RailsBridge 原样给）。
    /// 取数在 `HomeViewModel.loadRailPage`（切到某栏时再拉该栏、首次拉取后缓存，
    /// 喜欢栏每次切回都重拉——本地星标一点就变，壳版同款不缓存）。
    private struct RailSourceListView: View {
        @ObservedObject var viewModel: HomeViewModel
        @EnvironmentObject private var playback: PlaybackStore
        @EnvironmentObject private var nav: AppNavigation

        /// 跑马带卡宽（与环平面带同档，调用方按 tier 传；见 sourceContent）。
        let cardWidth: CGFloat
        /// 面板深场（调用方按专辑取色 field 传；卡片字色跟它走，与环卡同款）。
        let isDark: Bool
        /// 跑马带驱动（归 HomeView 所有，切来源不重建，见文件头 r31 节）。
        /// r43-2：第 2 件——驱动本身不动（任务禁改项）；entriesView/openedView
        /// 已改走环（自带模型驱动），驱动只剩 RailMarqueeView 挂着、
        /// 目前无调用方，留待环真机验证后另行退役，不在本轮动它。
        @ObservedObject var marqueeDriver: RailMarqueeDriver
        /// r43-2：第 2 件——尺寸档（环的 flatCard/ringCard 按它 + 屏宽/高算，
        /// 调用方按 tier 传，与每日环同路）。
        let tier: PlayerTokens.PlayerSizeTier
        /// r43-2：第 2 件——实测屏宽/高（环几何按它算，与每日环同路透传）。
        let screenWidth: CGFloat
        let screenHeight: CGFloat
        /// r43-2：第 2 件——rail 四栏共用的环状态机（HomeView 的 railRingModel，
        /// 与每日 ringModel / 榜单详情 rankSongsRingModel 各用各的；
        /// entriesView 与 openedView 切换时靠 cards 变化重同步）。
        @ObservedObject var ringModel: HomeCoverRingModel

        private var page: HomeRailPage { viewModel.selectedSource }
        private var platform: String { viewModel.selectedPlatform }

        var body: some View {
            Group {
                if viewModel.isOpenedCollection {
                    openedView
                } else if viewModel.railResults[page] == nil {
                    // r35-9（P0-2）：没旧内容时 250ms 内只留空白，之后才亮
                    // spinner；有旧内容时直接走下面的 error/empty/entries
                    // 分支留旧内容（套壳 250ms 保留旧内容同款）。
                    if viewModel.isRailPageLoading(page) && !viewModel.isRailSpinnerVisible(page) {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        loadingView
                    }
                } else if let error = viewModel.railResults[page]?.error {
                    errorView(error: error)
                } else if let reason = viewModel.railEmptyReason(for: page) {
                    emptyView(reason: reason)
                } else {
                    entriesView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                // r33-marquee：喜欢栏只在星标变了之后重拉一次——
                // PlaybackStore.toggleLike 置旗（lizi.native.liked.needsRefresh），
                // 这里消费并清旗。r31 之前是每次出现都 force 重拉，而加载态会切走
                // entriesView（带子消失）→ 加载完再出现 → 又重拉，无限重取循环，
                // 带子反复被拆、看着像冻住；r31-starred 的原意（从播放页点完星标
                // 回来看到新状态）由这面旗子保留，不用每次出现都拉。
                // 首次进入由 selectSource 拉，在飞的由 railLoadingPages 守卫挡，不会双拉。
                if page == .liked, viewModel.railResults[.liked] != nil,
                   UserDefaults.standard.bool(forKey: PlaybackStore.likedNeedsRefreshKey) {
                    UserDefaults.standard.set(false, forKey: PlaybackStore.likedNeedsRefreshKey)
                    viewModel.loadRailPage(.liked, force: true)
                }
            }
        }

        // MARK: - 面板内打开的歌单 / 专辑（r31）

        /// 点「我的歌单」/「我喜欢」里的歌单或专辑卡后，面板原地换成该集合的
        /// 全部歌曲卡片（r39-4：卡下两行字，歌名 + 演唱者；点一首就播；跑马带与来源列表
        /// 同一个驱动、同一速度一直向左滚；没封面用 DefaultCoverArt，见
        /// `RailMarqueeCardView.coverArt`）。歌多时曲目已全量取数
        /// （`railPlaylistTracks` / `albumDetail` 翻页取满），带子接着滚，
        /// 面板竖向可滚看全量——不是只放前几首。返回键回该来源列表。
        private var openedView: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: { viewModel.closeOpened() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("返回\(page.title(platform: platform))")
                        }
                        .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                        .foregroundColor(LiziTokens.ink2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回\(page.title(platform: platform))")
                    Text(viewModel.openedTitle)
                        .font(.liziBody(size: LiziTokens.size15, weight: .semibold))
                        .foregroundColor(isDark ? .white : LiziTokens.ink)
                        .lineLimit(1)
                    Spacer()
                    if !viewModel.openedTracks.isEmpty {
                        Text("共 \(viewModel.openedTracks.count) 首")
                            .font(.liziBody(size: LiziTokens.size12))
                            .foregroundColor(isDark ? .white.opacity(0.62) : LiziTokens.ink3)
                    }
                }
                .padding(.bottom, 8)
                if viewModel.openedLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("正在拉取\(viewModel.openedTitle)…")
                            .font(.liziBody(size: LiziTokens.size13))
                            .foregroundColor(LiziTokens.ink3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if let error = viewModel.openedError {
                    errorView(error: error)
                } else if let reason = viewModel.openedEmptyReason {
                    emptyView(reason: reason)
                } else {
                    // r43-2：第 2 件——打开的集合改走 3D 环（与 entriesView 同一套
                    // HomeCoverRingView + 共用 railRingModel；卡片 = 打开的全部
                    // 歌曲，点一张播一首的 onTap 原样透传；返回头/加载/失败/空态/
                    // 「查看全部」一律不动，环只换掉原来那条 RailMarqueeView）。
                    HomeCoverRingView(
                        model: ringModel,
                        marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                        tier: tier,
                        panelIsDark: isDark,
                        coverOnly: true,
                        screenWidth: screenWidth, // r39-5：第 5 件——实测屏宽，环几何按它算
                        screenHeight: screenHeight, // r43-1：第 1 件——实测屏高，判横竖屏用
                        cards: openedTrackCards.map(\.ringCard) // r43-2：第 2 件（成员初始化器顺序：cards 是末位存储属性，调用点必须放最后；run 45011589996 编译修）
                    )
                    Spacer(minLength: 0)
                    openedViewAllButton
                }
            }
        }

        /// 打开的集合的全部歌曲卡片（r39-4：卡下两行字，歌名 + 演唱者），点一张播一首
        /// （setQueue 整份曲目，从点中的那首起播）。
        private var openedTrackCards: [RailMarqueeCard] {
            let tracks = viewModel.openedTracks
            return tracks.map { track in
                RailMarqueeCard(
                    // r45-3：曲目卡 id 与曲目路同式（"platform:id"），不用
                    // "track-platform-id"——环模型拿 playingKey 在通用卡里
                    // 找在播曲目时才能对上，否则榜单详情 / 打开的集合里
                    // 开环锚点永远回手指卡、点中态永远跟不上当前播。
                    id: "\(track.platform):\(track.id)",
                    coverURL: track.coverURL,
                    title: track.title,
                    subtitle: track.artist,
                    onTap: { playback.setQueue(tracks, startAt: trackIndex(track, in: tracks)) }
                )
            }
        }

        /// 打开态的「查看全部」：进歌单/专辑详情整页（带子滚动看全量）。
        @ViewBuilder
        private var openedViewAllButton: some View {
            if let playlist = viewModel.openedPlaylist {
                Button(action: { nav.show(.playlist(platform: playlist.source, id: playlist.id, isRank: playlist.isRank)) }) {
                    HStack(spacing: 4) {
                        Text("查看全部（共 \(viewModel.openedTracks.count) 首）")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                    .foregroundColor(LiziTokens.ink2)
                }
                .padding(.top, 8)
                .accessibilityLabel("查看全部\(viewModel.openedTitle)")
            } else if let album = viewModel.openedAlbum {
                Button(action: { nav.show(.album(platform: album.source, id: album.id)) }) {
                    HStack(spacing: 4) {
                        Text("查看全部（共 \(viewModel.openedTracks.count) 首）")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.liziBody(size: LiziTokens.size13, weight: .medium))
                    .foregroundColor(LiziTokens.ink2)
                }
                .padding(.top, 8)
                .accessibilityLabel("查看全部\(viewModel.openedTitle)")
            }
        }

        // MARK: - 卡片跑马带层（r31：竖向列表改成与每日带同款的横向卡片跑马带）

        private var entriesView: some View {
            let entries = viewModel.railEntries(for: page)
            let cards = marqueeCards(entries: entries)
            let total = entries.filter { entry in
                if case .groupHeader = entry { return false }
                return true
            }.count
            return VStack(alignment: .leading, spacing: 0) {
                // r43-2：第 2 件——4 栏改走 3D 环（与每日推荐同一套
                // HomeCoverRingView + 共用 railRingModel；平面带 + 3D 环 +
                // 手势链全复用环的，不另写一套；入口提示行默认显示，与每日
                // 推荐一致，不传 hideEntryHint；卡片 = marqueeCards 原样转
                // 通用卡，点按行为（曲目 setQueue / 歌单面板内打开或进详情 /
                // 专辑面板内打开 / 电台进详情）原样透传；「查看全部」不动）。
                HomeCoverRingView(
                    model: ringModel,
                    marqueeSpeed: viewModel.marqSpeedPxPerSecond,
                    tier: tier,
                    panelIsDark: isDark,
                    coverOnly: true,
                    screenWidth: screenWidth, // r39-5：第 5 件——实测屏宽，环几何按它算
                    screenHeight: screenHeight, // r43-1：第 1 件——实测屏高，判横竖屏用
                    cards: cards.map(\.ringCard) // r43-2：第 2 件（成员初始化器顺序：cards 是末位存储属性，调用点必须放最后；run 45011589996 编译修）
                )
                Spacer(minLength: 0)
                viewAllButton(total: total)
            }
        }

        /// 面板卡片（r31）：把该栏条目展平成一张张卡——曲目卡与集合卡
        /// （歌单/专辑/电台本身）同一形状，都是封面 + 卡下两行字
        /// （r39-4：曲目卡歌名/演唱者，集合卡名字/副信息）；
        /// 分组说明卡（groupHeader）不是内容、不进带子。点按行为：
        /// 曲目点播；「我的歌单」/「我喜欢」里的歌单卡点后在面板内打开
        /// （`viewModel.openPlaylist`），专辑卡在面板内打开
        /// （`viewModel.openAlbum`）；其余来源的歌单卡进详情页。
        private func marqueeCards(entries: [RailEntry]) -> [RailMarqueeCard] {
            let tracks = entries.compactMap { entry -> Track? in
                if case .track(let track) = entry { return track }
                return nil
            }
            return entries.compactMap { entry in
                switch entry {
                case .groupHeader:
                    return nil
                case .track(let track):
                    return RailMarqueeCard(
                        // r45-3：曲目卡 id 与曲目路同式（"platform:id"），不用
                        // entry.id 的 "track-platform-id"——环模型拿 playingKey
                        // （"platform:id"）在通用卡里找在播曲目时才能对上，
                        // 否则开环锚点与点中态永远找不到正在播的那首（各栏 /
                        // 打开的集合里曲目卡不同步的根因）。集合卡的 id 不动。
                        id: track.platform + ":" + track.id,
                        coverURL: track.coverURL,
                        title: track.title,
                        subtitle: track.artist,
                        onTap: { playback.setQueue(tracks, startAt: trackIndex(track, in: tracks)) }
                    )
                case .playlist(let playlist):
                    return RailMarqueeCard(
                        id: entry.id,
                        coverURL: playlist.coverURL,
                        title: playlist.title,
                        subtitle: playlistSubtitle(playlist: playlist),
                        onTap: {
                            if page == .created || page == .liked {
                                viewModel.openPlaylist(playlist)
                            } else {
                                nav.show(.playlist(platform: playlist.source, id: playlist.id, isRank: playlist.isRank))
                            }
                        }
                    )
                case .album(let album):
                    return RailMarqueeCard(
                        id: entry.id,
                        coverURL: album.coverURL,
                        title: album.title,
                        subtitle: albumSubtitle(album: album),
                        onTap: { viewModel.openAlbum(album) }
                    )
                case .station(let station):
                    return RailMarqueeCard(
                        id: entry.id,
                        coverURL: station.coverURL,
                        title: station.name,
                        subtitle: stationSubtitle(station: station),
                        onTap: { nav.show(.rail(kind: "radio", platform: platform)) }
                    )
                }
            }
        }

        @ViewBuilder
        private func viewAllButton(total: Int) -> some View {
            if let kind = page.railKind {
                Button(action: { nav.show(.rail(kind: kind.rawValue, platform: platform)) }) {
                    HStack(spacing: 4) {
                        Text(total > 0 ? "查看全部（共 \(total) 项）" : "查看全部")
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

        // MARK: - 卡片副标题（歌单/电台卡的第二行；曲目卡第二行就是歌手）

        private func playlistSubtitle(playlist: Playlist) -> String {
            var parts: [String] = []
            if !playlist.creator.isEmpty { parts.append(playlist.creator) }
            if playlist.trackCount > 0 { parts.append("\(playlist.trackCount) 首") }
            return parts.joined(separator: " · ")
        }

        private func albumSubtitle(album: Album) -> String {
            var parts: [String] = []
            if !album.artist.isEmpty { parts.append(album.artist) }
            if album.trackCount > 0 { parts.append("\(album.trackCount) 首") }
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

    // MARK: - r31 rail 跑马带（驱动 + 视图 + 卡片）

    /// rail 跑马带里的一张卡（曲目 / 歌单 / 电台共用同一形状）：
    /// 封面 + 卡下两行字（r39-4：标题/副标题画在卡片下面，居中对齐卡片；
    /// 字段既画出来，也留给 VoiceOver 与点按路由）；
    /// 点按行为由调用方 `marqueeCards` 按条目类型填。
    private struct RailMarqueeCard: Identifiable {
        var id: String
        var coverURL: URL?
        var title: String
        var subtitle: String
        /// r35-3：是不是当前在播的那首（搜索歌单带用；r36 搜索带改用
        /// 首页环，searchQueueCards 已删，isCurrent 只剩 rail 各栏的
        /// 默认 false，渲染与原来一字不差）。
        var isCurrent: Bool = false
        var onTap: () -> Void

        /// r43-2：第 2 件——rail 卡 → 通用环卡（id/coverURL/title/subtitle/onTap
        /// 原样透传；isCurrent 只剩默认 false、渲染不动，不带过来）。
        /// 放这里是因为 `RailMarqueeCard` 是 HomeView 的 private 嵌套类型，
        /// HomeCoverRingView.swift 看不见它（extension 不能嵌套在类型里，
        /// 所以不用 `extension HomeRingCard` 的写法）。
        var ringCard: HomeRingCard {
            HomeRingCard(id: id, coverURL: coverURL, title: title,
                         subtitle: subtitle, onTap: onTap)
        }
    }

    /// r31：rail 跑马带驱动（与 HomeCoverRingModel 的平面带驱动同款：
    /// CADisplayLink + 真实帧间隔 dt，见 HomeCoverRingView.swift 文件头 r31 节）。
    /// - 归 HomeView 所有（@StateObject）：dailyPanel 的 `.id(selectedSource)`
    ///   只重建 sourceContent，驱动不重建；切来源时内容换了只归一化偏移
    ///   （`noteContentChanged`），不归零、不重停 2.5s——带子接着滚，不停、不跳。
    /// - 初画 2.5s dwell 只在驱动创建时走一次（与环的 initialDwell 同值）；
    ///   拖动松手停 1.2s（与环的 dragResumeDwell 同值）；速度由调用方按
    ///   viewModel.marqSpeedPxPerSecond 同步（默认 24px/s）。
    /// - r31-marquee（卡住修）：`isDragging` 原来只有一个出口
    ///   （DragGesture.onEnded），手势被打断就永远卡住、带子永远停；
    ///   现补两处出口——linkFired 里的 10s 看门狗（与环平面带 tickFlat
    ///   同款，拖动 10s 无位移即清）+ 视图被拆时 `dragCancelled()`
    ///   （RailMarqueeView.onDisappear 调）；回调不再经 Task 跳主线程
    ///   （见 `RailMarqueeLinkProxy`）。
    @MainActor
    final class RailMarqueeDriver: ObservableObject {
        @Published var offsetX: CGFloat = 0
        @Published var setWidth: CGFloat = 0
        @Published var isDragging = false

        var speed: CGFloat = 24

        private var dwellUntil = Date().addingTimeInterval(2.5)
        private var dragBase: CGFloat = 0
        /// 本次拖动的最后一次位移时间（r31-marquee 看门狗用，见 linkFired）。
        private var draggingSince: Date?
        private var displayLink: CADisplayLink?
        private var linkProxy: RailMarqueeLinkProxy?
        /// r31-settings-sections：120Hz 开关拨动通知的订阅 token（start()
        /// 里注册，deinit 里注销；通知回调当场重算已建 link 的帧率上限）。
        private var frameRateObserver: NSObjectProtocol?
        private var lastTimestamp: CFTimeInterval = 0
        /// r33-marquee 看门狗 Timer（display link 之外的第二条命）：
        /// link 死了或守卫卡住了，linkFired 里的 10s 看门狗也跟着死——
        /// 带子永远停。0.1s 看一次：该走（setWidth > 0、没拖动、dwell 已过）
        /// 但偏移 3s 没变 → 记一次诊断 + 清拖动旗 + dwell 归零 + 自己按
        /// 速度推一步（2.4px/步；link 活着时偏移每帧都在变，不会触发，
        /// 绝不与 link 打架）。deinit 停表。
        private var marqueeWatchdog: Timer?
        private var lastOffsetX: CGFloat = 0
        private var lastOffsetChange = Date()
        private var watchdogLoggedStuck = false

        // r45-2：退役——init 不再自动启动 link + 看门狗。RailMarqueeView
        // 自 r43-2 起全仓没有任何实例化（marqueeDriver 也没有任何读处），
        // 这个驱动从首页一打开就空转一条 120Hz CADisplayLink + 一条
        // 0.1s 看门狗，纯烧电。类本身留着（RailSourceListView 的参数
        // 还挂着它，不拆接线，只停空转）；将来真有视图再用时由视图
        // 显式调 start()（内部方法）；startWatchdog() 是 private，
        // 复活驱动时再把它改回内部方法。
        init() {}

        deinit {
            displayLink?.invalidate()
            marqueeWatchdog?.invalidate()
            if let frameRateObserver { NotificationCenter.default.removeObserver(frameRateObserver) }
        }

        /// r33-marquee：带宽兜底——setWidth 正常由 RailMarqueeView 的
        /// GeometryReader 偏好上报；偏好万一没到（视图没布局完就进守卫），
        /// linkFired 的 setWidth > 0 守卫永远不满足、带子永远停。
        /// 卡数×(卡宽+间距) 与偏好公式同值（偏好 = 内层宽 + 16 = n×(卡宽+16)），
        /// 只在 setWidth == 0 时补，不与偏好打架。
        func ensureSetWidth(cardCount: Int, cardWidth: CGFloat) {
            guard setWidth == 0, cardCount > 0 else { return }
            setWidth = CGFloat(cardCount) * (cardWidth + 16)
        }

        private func startWatchdog() {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchdogTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            marqueeWatchdog = timer
        }

        /// 看门狗每 0.1s 一跳：不该走时（拖动中 / dwell 未过 / 没内容）
        /// 只刷新基线，不误判；该走但偏移 3s 没变 → 记诊断 + 恢复并自己推一步。
        private func watchdogTick() {
            guard setWidth > 0, !isDragging, Date() >= dwellUntil else {
                lastOffsetX = offsetX
                lastOffsetChange = Date()
                watchdogLoggedStuck = false
                return
            }
            if offsetX != lastOffsetX {
                lastOffsetX = offsetX
                lastOffsetChange = Date()
                watchdogLoggedStuck = false
                return
            }
            guard Date().timeIntervalSince(lastOffsetChange) >= 3 else { return }
            if !watchdogLoggedStuck {
                watchdogLoggedStuck = true
                DiagLog.shared.recordLog(category: "marquee", message: "rail belt stuck 3s, watchdog driving", fields: ["setWidth": setWidth, "isDragging": isDragging, "offsetX": offsetX, "speed": speed])
            }
            isDragging = false
            draggingSince = nil
            dwellUntil = Date()
            offsetX = normalized(offsetX - speed * 0.1)
            lastOffsetX = offsetX
        }

        func start() {
            guard displayLink == nil else { return }
            let proxy = RailMarqueeLinkProxy(driver: self)
            let link = CADisplayLink(target: proxy, selector: #selector(RailMarqueeLinkProxy.fired(_:)))
            // r31-settings-sections：帧率上限跟设置页「120Hz 高刷新率」开关走
            //（SettingsStore.frameRateRange()：开 = 30–120/首选 120，
            // 关 = 30–60/首选 60；默认开，与 120Hz 工硬编码 120 的既有行为
            // 一致）。plist 解锁是编译期、运行时关不掉，开关能控的就是这行。
            link.preferredFrameRateRange = SettingsStore.frameRateRange()
            link.add(to: .main, forMode: .common)
            linkProxy = proxy
            displayLink = link
            // 开关拨动时已建好的 link 当场重算上限：设置页拨完回首页，
            // 驱动是 @StateObject、不一定重建，只靠 start 时读一次会漏；
            // 订阅只注册一次（本函数幂等，guard 拦住重复进），deinit 注销。
            // 闭包只弱持驱动，不循环引用；queue .main，所以回调必在主线程，
            // MainActor.assumeIsolated 安全（与 RailMarqueeLinkProxy 同款）。
            frameRateObserver = NotificationCenter.default.addObserver(
                forName: SettingsStore.highRefreshRateDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyFrameRateRange() }
                }
        }

        /// r31-settings-sections：120Hz 开关拨动时重算已建 link 的帧率上限
        ///（通知回调；link 没建好时是空操作，不重建 link、不碰 dt/步长）。
        private func applyFrameRateRange() {
            displayLink?.preferredFrameRateRange = SettingsStore.frameRateRange()
        }

        /// 内容换了（切来源 / 该栏重拉）：只把偏移收进新宽度，不归零、
        /// 不重停 dwell——带子接着滚，不停、不跳。
        func noteContentChanged() {
            offsetX = normalized(offsetX)
        }

        func dragBegan() {
            isDragging = true
            draggingSince = Date()
            dragBase = offsetX
        }

        func dragMoved(_ dx: CGFloat) {
            // 有位移 = 拖动还活着，看门狗计时从这次位移重算（见 linkFired）。
            draggingSince = Date()
            offsetX = normalized(dragBase + dx)
        }

        func dragEnded() {
            isDragging = false
            draggingSince = nil
            dwellUntil = Date().addingTimeInterval(1.2)
        }

        /// 拖动被外力打断后的清理（r31-marquee）：DragGesture 只有 onEnded
        /// 一个出口；视图在拖动中被拆掉（切来源/切平台/打开歌单/专辑、
        /// 分支切加载态）或手势被系统取消时 onEnded 到不了，isDragging
        /// 永远卡住、带子永远停。RailMarqueeView.onDisappear 调这里；
        /// 不推 dwell——带子应当接着滚，不停、不跳。
        /// 没在拖动时是空操作（正常切来源不影响带子）。
        func dragCancelled() {
            isDragging = false
            draggingSince = nil
        }

        /// display link 回调（主线程）：步长 = 速度 × 真实帧间隔 dt。
        /// dt 从 link.timestamp 差算；第一帧用 1/60s 起步；dt 夹到 0.1s，
        /// 后台回来 / 卡顿后不一次跳几十 px。60Hz 约 0.4px/步、120Hz 约 0.2px/步。
        fileprivate func linkFired(_ link: CADisplayLink) {
            let dt: CFTimeInterval
            if lastTimestamp == 0 {
                dt = 1.0 / 60.0
            } else {
                dt = link.timestamp - lastTimestamp
            }
            lastTimestamp = link.timestamp
            // r31-marquee 看门狗（与环平面带 tickFlat 的 10s 看门狗同款，
            // 见 HomeCoverRingView.swift）：isDragging 只有一个出口
            // （DragGesture.onEnded）；手势被打断（App 切后台、来电、
            // 滚动接管、视图被拆）时 onEnded 到不了，旗子永远卡住、
            // 带子永远停——r26 每日带就是这副样子（走了约 1s 的量后冻住）。
            // 10s 内没有任何拖动位移就不是真实拖动，直接清掉、让带子恢复；
            // dragMoved 每步都刷新计时，活拖动不会被误清。
            if isDragging, let since = draggingSince,
               Date().timeIntervalSince(since) > 10 {
                isDragging = false
                draggingSince = nil
            }
            guard setWidth > 0, !isDragging, Date() >= dwellUntil else { return }
            let clamped = min(max(dt, 0), 0.1)
            guard clamped > 0 else { return }
            offsetX = normalized(offsetX - speed * CGFloat(clamped))
        }

        /// 把偏移收进 (-setWidth, 0]，两份循环无缝（环平面带同款）。
        private func normalized(_ x: CGFloat) -> CGFloat {
            guard setWidth > 0 else { return x }
            var v = x
            while v > 0 { v -= setWidth }
            while v <= -setWidth { v += setWidth }
            return v
        }
    }

    /// r31：display link 回调代理（与 HomeCoverRingView.swift 的
    /// `FlatDisplayLinkProxy` 同款：link 强持 target，代理只弱持驱动，
    /// 不循环引用）。
    /// r31-marquee：回调不再经 `Task { @MainActor in }` 跳主线程——
    /// display link 已挂在 RunLoop.main 上，回调本身就在主线程；每帧
    /// 一个 Task 会让步长在任务队列里扎堆（几帧的量一次走完、再空几帧），
    /// 就是「一卡一卡」，dt 也要在回调当下读 link.timestamp，Task 里
    /// 读到的是更新后的戳。`MainActor.assumeIsolated` 在这里是安全的：
    /// link 只加在 .main 上，回调只可能在主线程触发。
    private final class RailMarqueeLinkProxy: NSObject {
        weak var driver: RailMarqueeDriver?

        init(driver: RailMarqueeDriver) {
            self.driver = driver
        }

        @objc func fired(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                self.driver?.linkFired(link)
            }
        }
    }

    private struct RailMarqueeWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    /// r31：rail 来源的卡片跑马带（每日推荐的环平面带同款形态，不同内容）。
    /// - 卡片横向排、内容复制两份循环，滚过一份宽度无缝回卷；
    /// - 自动向左滚，速度与每日带一致（viewModel.marqSpeedPxPerSecond，默认 24px/s）；
    /// - 驱动与环平面带同款 CADisplayLink + 真实帧间隔 dt（见 RailMarqueeDriver），
    ///   60Hz 约 0.4px/步、120Hz 约 0.2px/步，不一卡一卡；
    /// - 可横向拖动：拖动时暂停，松手 1.2s 后恢复（与环同值）；竖向滚动走
    ///   simultaneousGesture，不抢页面的竖滑；
    /// - 卡片是 Button（点一首就播 / 点集合进详情），DailyMarqueeView 同款做法。
    private struct RailMarqueeView: View {
        let cards: [RailMarqueeCard]
        let cardWidth: CGFloat
        let isDark: Bool
        @ObservedObject var driver: RailMarqueeDriver
        let speed: CGFloat

        var body: some View {
            Group {
                if cards.isEmpty {
                    Color.clear
                } else {
                    marqueeContent
                }
            }
            .onAppear {
                driver.speed = speed
                driver.ensureSetWidth(cardCount: cards.count, cardWidth: cardWidth)
                driver.noteContentChanged()
            }
            // r31-marquee：视图被拆掉时清掉可能残留的拖动旗（切来源/切平台/
            // 打开歌单/专辑、分支切加载态都走这里拆视图；DragGesture.onEnded
            // 在视图被拆时到不了，见 `RailMarqueeDriver.dragCancelled`）。
            .onDisappear { driver.dragCancelled() }
            .onChange(of: cards.map(\.id)) { _ in
                driver.ensureSetWidth(cardCount: cards.count, cardWidth: cardWidth)
                driver.noteContentChanged()
            }
            .onChange(of: speed) { _ in driver.speed = speed }
        }

        private var marqueeContent: some View {
            HStack(spacing: 16) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 16) {
                        ForEach(cards) { card in
                            RailMarqueeCardView(card: card, width: cardWidth, isDark: isDark)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: RailMarqueeWidthKey.self, value: geo.size.width)
                        }
                    )
                }
            }
            .offset(x: driver.offsetX)
            .onPreferenceChange(RailMarqueeWidthKey.self) { driver.setWidth = $0 + 16 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        if !driver.isDragging {
                            driver.dragBegan()
                        }
                        driver.dragMoved(value.translation.width)
                    }
                    .onEnded { _ in driver.dragEnded() }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
    }

    /// 跑马带里的一张卡：封面 + 标题 + 副标题（r39-4：第 4 件，卡下两行字：
    /// 标题 16pt 粗体 + 副标题 14pt，居中对齐卡片；曲目卡就是歌名 + 演唱者，
    /// 歌单/专辑/电台/榜单卡是名字 + 副信息，只加这两行，不加别的；
    /// 卡宽/卡高/间距不动，点按行为不变）。
    /// r37-1 追加（用户 2026-11-22 00:39 显示逻辑）：封面没显示出来时先盖
    /// 标题文字占位（白字盖在深色占位底上），用户能先滑、认出是哪张卡；
    /// 封面一到占位消失、只剩封面。占位盖在封面框里，不占卡高。
    /// 没封面（coverURL 为 nil）用 r30 的 DefaultCoverArt 深色默认图，不摆白卡；
    /// URL 有但加载失败时 CoverImageView 的白占位是已知残留（见 HomeCoverRingView
    /// 文件头 r30 节），与环卡同款。
    /// isDark：标题/副标题字色跟它走（深场白字，浅场墨字），与环卡同款。
    private struct RailMarqueeCardView: View {
        let card: RailMarqueeCard
        let width: CGFloat
        let isDark: Bool

        /// r37-1 追加：这张卡的封面图是否已显示（`CoverImageLoader` 进程内
        /// 缓存观测；false = 占位底 + 标题占位，true = 只剩封面）。
        /// 观测与 `CoverImageView`（`ProxyImageView`）走同一份加载器、同一
        /// 个在飞任务——不重复发请求；失败重试节拍（0.5s / 1.5s、最多 3 次）
        /// 照抄 `ProxyImageView`，免得图到了占位还赖着不走。
        @State private var coverLoaded = false

        var body: some View {
            // r39-4：第 4 件——卡下两行字（标题 16pt 粗体 + 副标题 14pt，
            // 居中对齐卡片；曲目卡就是歌名 + 演唱者，歌单/专辑/电台/榜单卡
            // 是名字 + 副信息，只加这两行，不加别的）。封面本身不动；
            // 副标题为空时画一个空格占一行行高，各卡同高、封面都在同一条
            // 平行线上。点按行为不变（Button 只包封面）。
            VStack(alignment: .center, spacing: 7) {
                Button(action: card.onTap) {
                    ZStack(alignment: .center) {
                        coverArt
                            .frame(width: width, height: width)
                            .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                            // r35-3：当前在播的卡高亮（封面 accent 描边）；isCurrent
                            // 为 false 时描边透明（r39-4：标题行回到卡片下方，
                            // 高亮只剩封面描边）。
                            .overlay(
                                RoundedRectangle(cornerRadius: LiziTokens.radius10)
                                    .stroke(card.isCurrent ? LiziTokens.accent : Color.clear, lineWidth: 2)
                            )
                        // r37-1 追加：封面未显示时的标题占位（无封面 URL 的卡永远
                        // 无图可显，占位一直显示——那是唯一能认出卡的办法；有封面
                        // URL 的图一到即消失，不变常驻标题）。
                        if !coverLoaded {
                            VStack(alignment: .center, spacing: 2) {
                                Text(card.title)
                                    .font(.liziBody(size: LiziTokens.size15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                if !card.subtitle.isEmpty {
                                    Text(card.subtitle)
                                        .font(.liziBody(size: LiziTokens.size12))
                                        .foregroundColor(.white.opacity(0.75))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                Text(card.title)
                    .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                    .foregroundColor(isDark ? .white : LiziTokens.ink)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                Text(card.subtitle.isEmpty ? " " : card.subtitle)
                    .font(.liziBody(size: LiziTokens.size14))
                    .foregroundColor(isDark ? .white.opacity(0.62) : LiziTokens.ink3)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
            }
            .frame(width: width, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(card.isCurrent ? "正在播放 \(card.title)" : card.title)
            .task(id: card.coverURL) {
                // r37-1 追加：观测封面是否已显示（见 coverLoaded 注释）；
                // url 一变任务重开，coverLoaded 先归 false（旧图不顶替新卡）。
                coverLoaded = false
                guard let url = card.coverURL else { return }
                var attempt = 0
                while !Task.isCancelled, !coverLoaded {
                    if await CoverImageLoader.shared.image(for: url) != nil {
                        coverLoaded = true
                        break
                    }
                    attempt += 1
                    guard attempt <= 2 else { break }
                    try? await Task.sleep(nanoseconds: UInt64((attempt == 1 ? 0.5 : 1.5) * 1_000_000_000))
                }
            }
        }

        @ViewBuilder
        private var coverArt: some View {
            if card.coverURL == nil {
                DefaultCoverArt(iconSize: 64)
            } else {
                CoverImageView(url: card.coverURL, placeholderIconSize: 64)
            }
        }
    }

    // MARK: - 顶栏

    /// r22j：照抄壳版 `.topbar` + `.brand`（`public/index.html` 约
    /// 109–131 行 + `public/app.css` 约 269–303 行），一行、定高 64、
    /// 左列设置齿轮 38 + 搜索 38（平面按钮、无底色；设置在前、搜索在后，
    /// 与壳版 DOM 顺序一致）、品牌真居中。
    ///
    /// 品牌不是抠图、不是图片资源（用户 04:56 纠正：抠图以后会出新 bug，
    /// 两张抠图已删，不许再用；2026-11-21 06:35 再明确：品牌是打上去
    /// 而不是贴图）：LI 标记和 LIZI 四个字母是 SwiftUI Path
    /// 按壳版内联 SVG 坐标照抄画出来的矢量（`BrandViews.swift` 的
    /// `BrandMarkView` / `BrandWordView`，缩放不糊、深浅底都不怕）；
    /// kun 是真文字（Fraunces 斜体 500、11px，包里 r19 已接的字体，
    /// 直接 Text 打）。三件套合在 `BrandLockupView` 里，顶栏与设置
    /// 关于页共用同一份。
    /// r28：尺寸不再照壳版 CSS（17×17 / 34×15），按用户首页截图实测
    /// 1:1 校准——LI 16.7×11.7、LIZI 33.3×10.7、kun 宽 18.3、
    /// 间距 LI→LIZI 9.3、LIZI→kun 9.7（截图 1206×2622 @3x，÷3 为 pt）；
    /// 整体仍居中，纵向位置不动。旧 gap 9（壳版 `.brand` gap 9px）
    /// 已被 r28 的 9.3 / 9.7 取代，见 `BrandLockupView`。
    /// r31：LI 标记曾画在屏外（`scale.concatenating(translate)` 的
    /// 拼接顺序与字面相反，r26「修复」等于没改，见 BrandViews.swift
    /// 文件头）；本轮改成写死合成矩阵，墨迹回到 16.7×11.7 框内。
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
            // r31：品牌三件套见 BrandViews.swift 的 BrandLockupView
            // （LI + LIZI + kun，r28 定稿尺寸/间距，同一基线）；
            // 设置关于页用的也是它，两处是同一枚品牌。
            BrandLockupView()
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
