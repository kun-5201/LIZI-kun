import SwiftUI
import UIKit

/// 首页 3D 封面环（r21）：平面跑马带常态 + 手势展开全屏 3D 圆环。
///
/// 视频逐帧规格（~/workspace/user/media_library/video/9e/9ee7dd02…3203.mp4，
/// 4.05s/30fps，逐帧图 ~/workspace/home3d-frames/f_001–f_041，10fps）：
/// - 0.0–0.9s：平面跑马带，两张大卡并排、歌名+歌手在下，自动向左慢滚
///   （实测 f_001→f_010：0.9s 左移 24 帧像素 ≈ 17pt ≈ 19pt/s；壳版
///   ring.js MARQUEE_SPEED=24，与原生跑马带默认 24→约 22px/s 同值）。
/// - 约 0.9–1.0s：上滑展开环（f_010 还是平面，f_011 环已展开约八成；
///   壳版 ring.js ENTER_MS=520 easeOutQuint，0.15s 即到 82%，吻合）。
/// - 1.0–1.5s：手指持续向左拖，环跟着转，中间依次是你的万水千山2026 →
///   南风北巷 → 荒 → 阴天快乐（每槽约 0.35–0.4s）。
/// - 约 1.5s 松手：惯性继续向左滑，约 2.1s 停在求你别离开我dj（动量
///   投影到目标槽位 + 弹簧吸附，见 releaseRing 一段）。
/// - 约 2.5s：松手 1s 到点，环 430ms 收回平面带（f_026 收回中，f_030
///   已回平面带）。
/// - 约 2.9s：点求你别离开我dj，播歌 + Hero 渐变成该首（f_030 渐变中，
///   f_034 完成）。
/// - 3.4s：用户切出 App。
/// - 环开着时全屏变暗：Hero 区平均亮度 63.2→38.1（约 0.60 倍），顶栏区
///   174.4→67.2（约 0.39 倍）——壳版 .mring 径向渐变（中心 0.40 →
///   56% 处 0.70 → 边缘 0.88）正好复现这个分布。
/// - 环卡下方每张都有歌名+歌手，底部居中提示「拖动旋转 · 点击播放 ·
///   松手收回」（视频原字；壳版 ring.js 的提示是「拖动旋转 · 点卡片播放」，
///   以视频为准）。
///
/// 壳版依据：public/m/ring.js（MobileRing）+ public/m/ring.css。运动模型
/// 原样照搬，只改视频里能量出来的两个尺寸（环卡、平面卡见下表）：
/// 平面带：MARQUEE_SPEED=24、松手 1200ms 后恢复、初画停 2.5s；
/// 开环（r40：改回 r24）：平面带上横向拖动就开环（10px 内不判方向；
/// 竖向占优 |dy|>|dx|×1.25 才交还 ScrollView，上/下都一样）；
/// r39-5 的上滑开环 + 横向手滚跑马带已删。
/// 圆柱：pitch=卡宽×1.14（壳版；r35 前 r31 的「视频实测 pitch≈卡宽」
/// 已作废，见下 r35），R 取弦长公式；透视 P=3.2R；相机 translateZ(-R) rotateX(-5°)；
/// 拖动：每像素 180/(πR)×1.45 度；角速度取最近 110ms 采样，限幅
/// ±1400°/s；惯性 τ=1.08s，目标 = 离 (angle+v·τ·0.55) 最近的槽位；
/// 弹簧 118、阻尼 2√118（临界阻尼）；只露正面 facing≤0.06 藏，
/// 0.06–0.30 smoothstep 淡出；远端压暗 0.55·((1-facing)/2)^1.25；
/// 松手保持 1000ms 后收（430ms），点空白快收（220ms），明显下滑
/// （>90px）退出；点卡片播放并收回。
///
/// r20 与视频对不上的地方（本轮逐项改掉）：
/// 1. 常态：r20 永远是 3D 环；视频常态是平面跑马带，环只在手势期间出现。
/// 2. 自动滚动：r20 完全没有；视频平面态自动左滚。
/// 3. 触发：r20 横向滑动直接切歌（56px 阈值）；视频是上滑展开环，横向
///    拖动只滚跑马带。
/// 4. 环几何：r20 照抄播放页 CoverFlow（±40°/±50°、scale 0.91/0.85、
///    偏移 ±128/±224、带倒影）；视频是圆柱环、无倒影。
/// 5. 文字：r20 环上无任何文字；视频每张环卡下有歌名+歌手、底部有提示。
/// 6. 松手：r20 滑一下切一首、无惯性；视频松手惯性+弹簧吸附、保持 1s
///    后收回。
/// 7. 点封面：r20 点当前封面是播放/暂停切换、环不收回；视频点任意卡片
///    = 播放该首 + 收回环，Hero 渐变到该首。
/// 8. 顶部变暗：r20 没有；视频环开着时全屏径向变暗。
/// 9. 尺寸：r20 环卡 168/188/208（播放页 coverItem）；视频环卡约
///    0.39vw、平面卡约 0.51vw。
/// 10. 下滑退出：r20 无；视频/壳版环里明显下滑退出。
/// 11. 协调员小结的「圆环继续向左自动旋转」实为松手后的惯性滑向目标槽位
///     （1.5–2.2s）：壳版 ring.js 里环本身没有自动旋转，自动的只有平面
///     跑马带；本轮不给环加自动旋转。
///
/// 尺寸分档（r21：一档一套固定尺寸，不加任何 MagnificationGesture；
/// 视频实测，720px 原帧量取，档中宽 370/397/430pt）：
/// - 平面卡：卡宽 ≈ 0.486vw → compact 180 / standard 190 / large 209
///   （39.6s 新视频：卡 350px/720px；旧 4s 视频是 0.51vw → 188/202/220），
///   间距 16。
/// - 环卡：卡宽 ≈ 0.382vw → compact 141 / standard 149 / large 164
///   （新视频中心卡 275px/720px；旧视频 0.39vw → 144/156/168）；
///   槽距 step 40°（侧卡实测倾角约 40°）；pitch = 卡宽×1.14
///   （壳版 ring.js；旧视频 pitch=卡宽已作废）；
///   R = pitch / (2·sin 20°) ≈ 235 / 248 / 273。
/// - 7 个平台同一套环，不分平台分支。
///
/// 内容：队列优先、每日兜底（与 r20 同款），两份都空就不显示环、
/// 不编假封面；加载中 / 每日为空时显示与 DailyMarqueeView 同款文案。
/// 平面态 r28 起按在播专辑取色（HomeView AlbumTone；旧句「浅色样式不改」
/// 已作废，用户 01:58 澄清面板跟专辑走）；环上不加「正在播」accent
/// 圈（视频里没有）。
/// HomeView 里的 DailyMarqueeView 调用已撤掉：环的平面态就是每日跑马带，
/// 两处并存会上下叠两条一样的带（DailyMarqueeView.swift 文件留着未删）。
///
/// 结构：状态机在 `HomeCoverRingModel`（HomeView 持有 @StateObject，
/// 平面带与全屏覆盖层共用）；`HomeCoverRingView` 只画平面带；
/// `HomeRingOverlayView` 是全屏覆盖层，由 HomeView 挂在根 VStack 的
/// `.overlay` 上（在 ScrollView 之外，变暗才能盖住 Hero/顶栏/平台条；
/// 挂在 ScrollView 里的子视图上会被 ScrollView 裁切）。
///
/// r22c 纠正（2026-11-20）：r21 的环只存在于代码里，真机上打不开——
/// 用户原话「没有这个功能，这个是以前网页套壳那个版本给你截图的」。
/// 根因（两处，都是手势在真机上根本到不了模型）：
/// 1. 平面带在竖向 ScrollView 里，上滑被 ScrollView 抢走去滚页面了：
///    SwiftUI `.simultaneousGesture` 拦不住 ScrollView 的竖滑。
///    壳版的等价物是 `.mstrip { touch-action: none; }`——带子拥有全部触摸。
///    本轮改成 UIKit `UIPanGestureRecognizer`（`StripTouchView`，见文件尾）：
///    `shouldBeRequiredToFailBy` 让 ScrollView 的 pan 等我们的 pan 先失败，
///    方向判定后下滑才自毁认输、把手势交还 ScrollView；上滑/横向由我们接管。
///    同一根手指从按下一路管到开环、转环、松手（壳版 window pointer 监听同款），
///    不再依赖「覆盖层半路出现后新 DragGesture 能接到旧触摸」这种不可靠行为。
/// 2. 覆盖层点卡用 `DragGesture(minimumDistance: 5)` 的 onEnded 判点按：
///    纯点按（位移 <5px）根本触发不了 DragGesture，点卡播歌是死的。
///    本轮点按改走 `.onTapGesture`（带位置），拖动仍走 DragGesture；
///    <5px=点按、≥5px=拖动，与壳版 RING_THRESHOLD=5 同款分界。
/// 另补两处截图对照：环卡歌名/歌手左对齐（r21 居中，截图 8 张全是左对齐，
/// 壳版 `.mring__name` 默认左对齐）；平面带下加可见入口提示行
/// （用户现在根本找不到环）。
/// 拖动时顶部再暗一档（`isRingDragging` 驱动，视频：拖动时顶部大卡片变暗）。
/// 本轮只动本文件；播放页、闪退相关文件、HomeView.swift 一行不动。
///
/// r24（2026-11-20，第 3/4/5 件，手势链按视频 + ring.js 重写——不是 r22c
/// 代码换参数：旧的「上滑开环」判定、覆盖层 SwiftUI DragGesture +
/// onTapGesture、架子那套全部删掉，改为两处 UIKit 触摸层 + 模型同一套
/// 入口；用户原话「后面我会查看代码，不能拿以前的代码」）：
/// - 第 3 件（用户原话「修复 3d 封面要上滑的 bug」「就是要上滑才能转动」）：
///   上滑门槛删掉。平面带上横向一拖就开环，手指不抬起继续拖就是转环
///   （ring.js enterRing「手指不用抬起，展开后继续拖就是转环」，
///   触发条件从「上滑」改成「横向」；视频 0.9–1.0s 的上滑展开动作本身
///   不再是必要步骤——用户最新指令优先于视频这一处）。
///   竖向拖动（上/下都一样）交还 ScrollView 滚页面，不再开环。
/// - 第 4 件（「3D 封面只会在中间」「下面的专辑也无法转动」）：
///   环只停中间的根因是开环后的第二根手指走覆盖层 SwiftUI
///   DragGesture——它与同视图的 onTapGesture 叠在一起，真机上到不了
///   模型，角一直停在 0。重写后覆盖层触摸走 UIKit RingTouchView
///   （UIPan + UITap，tap require(toFail: pan)，与 StripTouchView
///   同款；r23 长按死锁的教训：每个触摸面只挂一对识别器，不叠
///   highPriority / sequenced / 长按）。专辑架见 MyAlbumsView.swift 文件头。
/// - 第 5 件：其余行为照视频 + ring.js（自动跑马带 24px/s、展开
///   520ms easeOutQuint、每像素 180/(πR)×1.45°、110ms 采样限幅
///   ±1400°/s、τ=1.08s 投影 + 118 临界阻尼弹簧吸附、松手 1s 后
///   430ms 收回、点空白 220ms 快收、下滑 >90px 退出、底部提示
///   「拖动旋转 · 点击播放 · 松手收回」、径向变暗 + 拖动时顶部再暗一档）。
///   尺寸仍按视频实测（平面卡 0.51vw、环卡 0.39vw）。
/// - 约束（用户长期规则）：全程不加任何捏合/双击缩放手势；只旋转与
///   展开/收回。横屏竖屏同一套（尺寸按 tier 分档，与朝向无关）。
///
/// r26（2026-11-20，首页自动滚动修复：22:29 真机截图，正在播《半岛铁盒》，
/// 首页没有任何一处在自己动）：
/// - 断点（两处，都是跑马带驱动，不是速度值——默认速度验算 21.84pt/s，
///   约等于 22pt/s 定稿，没错）：
///   1. 驱动是 View 结构体的 `Timer.publish(...).autoconnect()` +
///      `.onReceive`：每次 body 重算（跑马带自己每 1/30s 改一次
///      flatOffsetX、播放进度每 0.25s 推一次）都造一个新 publisher
///      并重新订阅，33ms 倒计时反复重启，计时器可能永远等不到触发。
///      截图里带子只走了约 1s 的量（约 19–35pt，首卡「半岛铁盒」被
///      截成「铁盒」）就冻住，与这条对得上。
///   2. r24 把 `flatDragging = true` 从「横向判向后」提前到
///      `stripTouchBegan`（pan .began，任何一根移动的手指都停带）：
///      停带的入口变多了，清掉的出口却只有 stripTouchEnded——识别器
///      走 `.failed`、触摸被系统取消、触摸层中途被拆（数据重载切分支、
///      旋转换竖横分支）时，ended 到不了模型，旗子永远卡住，带子
///      永远停；没有任何别的写点能清它。
/// - 修法（只动本文件）：驱动改成模型自持的 30Hz Timer（一次创建、
///   `.common` 模式，页面滚动时也走），不随 body 重建；`flatDragging`
///   的出口补齐（pan `.failed`、touchesCancelled、触摸层被移除），
///   再加 10s 看门狗兜底；模型释放时 deinit 停表（RunLoop 强持 Timer，
///   切页重建 HomeView 会漏 Timer，不停每回首页漏一个 30Hz 空转 Timer）；
///   tickFlat 的步进、回卷、初画 2.5s、松手 1.0s、收回 0.22s、速度公式
///   一律不动；环本身不加自动转。
///
/// r26-3D（2026-11-20，3D 显示修复：22:29 截图 + 用户 22:31/22:33）：
/// 逐帧对照 02:53 视频 + 壳版 ring.js/ring.css/m.css 之后改的三处（另两处
/// 是核对结论，只写文档不改代码；详见 verification/r26-3d-check.md）：
/// 1. 内容跟来源走（壳版行为）：环/跑马带不再队列优先——内容永远是当前
///    平台的每日推荐（`tracks == dailyTracks`）。r20 的队列优先让切平台后
///    首屏看不到变化（22:29 截图：精选 chip 选中，面板里仍是队列的两张卡；
///    r26 来源删除工人的旧排查结论同款结构问题）：壳版 `ringItems()` 永远
///    是当前来源 S.items，`applyResult` 每次切平台/切来源都 `setItems`；
///    Hero 永远是当前播放那首（`applyResult` 注释原话），与带子无关。
///    点环卡/平面卡 = `setQueue(daily, startAt:)`（壳版 `activate(i)` 同款，
///    按下标播，重复曲目也不会播成第一张；r25 U6e 的环内 queueId 分支随
///    队列模式一起退役，见 verification/r25.cjs 的 U6e 更新说明；
///    U6a–U6d 的 play(queueItem:) 应用点——播放器队列行、封面流——不动）。
///    每日为空时诚实空态（壳版 ringMsg「这一层没有内容」同款），不拿队列顶。
/// 2. 当前播的歌在环中间（用户 22:33 原话）：开环锚点 = 在播曲目在当前
///    列表里的下标（在才用；不在——比如从搜索播的歌不在每日里——回落手指
///    卡/正中卡，即壳版/视频的锚点规则）。壳版与视频的锚点是手指卡
///    （nearestFlatIdx），本条按用户最新指令改了锚点规则；拖动连续性不变
///    （开环角仍从 0 起、ringStartX 仍是手指 x，继续拖就是转环）。
/// 3. 相机 -5° 下坠 + 环中心上下限（ring.js openRing / renderRing）：
///    原生之前把环卡排在 z=0 的平面上、容器 rotateX(-5°) 实际不产生下坠；
///    壳版相机 `translateZ(-R) rotateX(-5°)` 让正前方卡片下坠 R·sin5°
///    （标准档约 20pt；视频实测环中心比带中心低约 28–33pt，公式值 20pt，
///    残差在量取误差内）。本轮按槽位逐卡加下坠 `R·cos(world)·sin5°`，
///    点按命中同步用同一纵坐标。环中心另按 ring.js 上下限夹取
///    （顶栏底 + 卡高×0.55 + 12 / 屏底 − 卡高×0.55 − 52 − 下坠），
///    带子被滚到屏顶附近时环不再顶到顶栏/灵动岛底下；平时不触发。
/// 核对结论（不改代码）：① 22:29 截图里环不是没渲染——平面带在、环是
/// 默认收起态；看不见的是唯一可见入口提示行，
/// r25 时 chips 占 40pt 把它顶出屏底，chips 删除后（当前树）竖屏默认
/// 面板 382、竖滑区 312 > 内容 285，入口可见（2–27pt 余量，见驱动）；
/// ② 视频逐帧几何（平面卡 0.51vw、环卡 0.39vw、槽距 40°、无倒影、左对齐
/// 歌名+歌手、提示原字、变暗 0.59/0.38 倍）与原生实现逐项对得上，不改；
/// ③ 视频是平圆柱——各卡顶边齐平（±15px 量取噪声），不是 Android 包里
/// 2026-11-13 的螺旋版（相邻槽抬 1/3 卡高）；当前壳版 ring.js 也是平圆柱，
/// 原生不做螺旋。④ 壳版与视频的卡尺寸互不一致：视频环卡 0.39vw、
/// 手机 ring.js 公式 0.24vw（96.5pt）、手机 m.css 平面卡 16vw（64pt，
/// 环视口最高 196pt）——原生跟视频（r21 已定），见核对文档。
/// ⑤ 平面带在外层 ScrollView 的内容流里（面板 → 外层竖滑），竖滑页面时
/// 跟着走、不滞留；展开态环是全屏固定覆盖层（壳版 .mring position:fixed
/// 同款，按 stripCenter 锚到带子原位置），环本身不自动转。
///
/// r28（2026-11-21，39.6s 新视频 ~/workspace/user/media_library/video/a0/
/// a03d735e…4a14d.mp4，逐帧规格 verification/shell-video-39s-home-3d.md；
/// 以这段新视频为准，r21–r24 的 4 秒旧视频作废）：
/// - 尺寸按新视频重标：平面卡 350px/720px ≈ 0.486vw → 180/190/209；
///   环卡中心 275px/720px ≈ 0.382vw → 141/149/164；槽距 pitch =
///   卡宽×1.14（壳版 ring.js；旧视频的 pitch=卡宽作废），step 仍 40°，
///   R = pitch/(2·sin20°) ≈ 235/248/273。
/// - 环卡字：歌名 15pt 白、歌手 13pt 灰（旧 13/11）；平面卡歌名 16pt、
///   歌手 14pt（旧 14/13），颜色跟面板深场走（白字/墨字，见 panelIsDark）。
/// - 松手恢复：平面带拖动松手后 1200ms 恢复自动走（旧 1.0s；
///   resumeMs=1200 一直是这个值，dragResumeDwell 之前没对上）。
/// - 变暗：径向变暗改 0.36/0.58/0.78（新视频整页实测 0.42 倍；旧
///   0.40/0.70/0.88 按面积均值算约 0.26 倍，太暗）；提示字 11pt。
/// - 卡行底座：平面带 + 提示行外面一块更深的圆角底（黑 0.18，视频
///   f_001 里卡行就在一块更深的圆角底上）。
/// - 不自动开环（用户 01:57 原话「3d 环不是自动展开的是我手滑动才展开的」）：
///   本文件核对过——openRing 只有一个调用点，用户手动触发
///   （平面带横向拖动 stripTouchMoved；入口按钮点按 entryHintRow
///   已在 r28 删掉，点按开环不在触发里），没有任何定时器、onAppear、
///   加载完成回调能开环；tickFlat 只走跑马带，从不写 ringPhase。
///   常态永远是平面跑马带。
///
/// r30（2026-11-21，3D 环改版，v5 图口径：lizi-home-3d-ring-v5.png +
/// shell-video-frames f_050/f_055/f_060/f_070 实拍；只动本文件）：
/// - 核对结论（不改代码）：触发（跑马带横向拖动开环、竖向交还 ScrollView、
///   openRing 唯一调用点 stripTouchMoved，无自动开环）、变暗 0.36/0.58/0.78
///   （整页约 0.45 倍，f_050 亮度 121→51）、环带纵向（stripCenter 锚点，
///   封面约屏高 53%–71%）、提示（11pt，屏高约 94%）、几何（pitch=卡宽×1.14、
///   侧卡 ±40°、透视 3.2R、相机 translateZ(-R) rotateX(-5°)、facing
///   0.06 藏 / 0.06–0.30 淡出、压暗 0.55·((1-facing)/2)^1.25）、展开 520ms
///   easeOutQuint / 收回 430ms / 点空白 220ms 快收 / 松手 1s 后收 /
///   惯性 τ=1.08s + 弹簧 118 吸附 / 点卡播歌收回 / 下滑 >90px 退出——
///   逐项对上，不动。
/// - 改的四处：(1) 一次只见 3 张：visibleSlots 由中心±2 收成中心±1
///   （world ±40°；±80° 的卡本来就在屏外）；(2) 侧卡面板裁切：环层按面板宽
///   （带子宽 + 两侧各 20pt = 面板 padding 10 + 本文件 VStack padding 10，
///   圆角 22 与 dailyPanel 同值）框住 + clipShape，命中测试同步拦面板外点按；
///   注意：v5 图要求面板裁切，实拍 f_050/f_055 里侧卡实际溢出面板到屏边——
///   按任务 v5 图口径做面板裁切；(3) 环开着时平面带彻底让位（壳版
///   `body.is-ring .mstrip { opacity: 0 }` 同款，透明度跟 overlayOpacity 走），
///   环下面不再透出多余的专辑卡；(4) 没封面的卡不再摆白卡：coverURL 为 nil
///   时画深色默认封面（壳版 `.mring__card.is-empty` 深色底 +「无封面」同款
///   做法，原生用深色渐变 + music.note），FlatRingCard 与 RingCardView 共用
///   DefaultCoverArt；URL 有但加载失败的白占位在 CoverImageView.swift 里，
///   本文件动不了，见交回残留。
///
/// r31（2026-11-21，环跟着面板走，用户 05:37 已定，不等截图直接做）：
/// - 根因：`ringCenterY` 从 ring.js 照搬了 cy 上下限夹取
///   （顶栏底 + 卡高×0.55 + 12 / 屏底 − 卡高×0.55 − 52 − 下坠），
///   竖屏上限 663pt、横屏上限 194pt；Hero 拖大后带心约 775pt、横屏
///   带心约 433pt，都被钉回上限，环与带子脱节——用户原话「中心钉在
///   屏幕 0.5/0.48 不动」。变暗中心也固定在 UnitPoint(0.5, 0.48)，
///   卡片动了、光晕不动，脱节更明显。
/// - 改法（只动定位）：`ringCenterY` 去夹取，环中心 = stripCenter
///   （横向 panelRect 本来就是 stripCenter.x，纵向现在也是），
///   没量到才回落屏高 ×0.62；变暗中心改成同一个环中心
///   （body 里 ringCy/ringCx 一处算出，卡片与光晕同锚点）；
///   命中测试与环层共用 ringCenterY，点按盒跟着走。
///   夹取删除后，带子被滚到屏顶/屏底边缘时环跟着过去（可能半遮顶栏
///   或出屏），这是「跟着面板走」的本意；环开着时覆盖层挡住触摸，
///   本来也滚不动页面、拖不了分界手柄，面板动只剩旋转与布局变化。
/// - 不动：转动机制（跟手 perPixel、110ms 采样 ±1400°/s、τ=1.08s 投影 +
///   弹簧 118 吸附、只露正面、收回时机）、展开手势（跑马带左右拖动，
///   不要上滑）、变暗三档、一次 3 张、面板裁切（本段写于 r31 前半段；
///   面板裁切后在 r31 真圆柱一段作废，见文件头 r31 真圆柱节）。驱动见
///   verification/r31-ring.cjs。
///
/// r31（2026-11-21，跑马带平滑 + 其余 5 个来源也走卡片跑马带，见 HomeView.swift）：
/// - 驱动：30Hz Timer → CADisplayLink（本文件 `startFlatTimer` /
///   `tickFlat(dt:)`）。用户原话「跑马灯都不走，一直一卡一卡的」——
///   根因是驱动，不是速度值（24px/s 验算没错）：
///   ① 30Hz 下每步 0.8px，在 60/120Hz 屏上每帧都是一次离散跳变，
///   肉眼就是一顿一顿；② Timer 回调还要经 `Task { @MainActor in }`
///   跳一次主线程，调度抖动会丢步、停滞；③ flatOffsetX 是本模型
///   （环状态机）的 @Published，每跳都让整个环视图重新求值
///   （播放进度 0.25s 也在推同一批观察者），主线程一挤就卡。
///   改成 display link 后每帧一步（60Hz 约 0.4px、120Hz 约 0.2px），
///   步长按真实帧间隔 dt（link.timestamp 差，上限夹 0.1s）算，
///   丢帧后下一步自动补上，位移严格按速度×时间走；回调直接在主线程
///   跑（display link 挂在 RunLoop.main 上，代理里 `MainActor.assumeIsolated`
///   直调 tick，不再经 Task 跳主线程——r31 第一推这里写的是直调、
///   代码里其实还留着 Task 跳线程，r31-marquee 才真去掉，
///   见 `FlatDisplayLinkProxy`）；弱引用代理仍保留（display link 强持
///   target，不用代理模型永远不释放）。初画停 2.5s、松手 1.2s 恢复、
///   10s 看门狗、环开着停带、速度 24px/s 一律不动。
///   取色已核过：AlbumToneExtractor 是 32×32 采样 + k=4 最多 10 轮，
///   毫秒级，且只在切歌时跑一次，不是卡顿来源，不动它；
///   实现是 offset 位移（不是 ScrollView 编程式滚动），没有 layout
///   跳变；回卷只按一份宽度归一化，不跳整张卡宽。
/// - DefaultCoverArt 去掉 private：其余 5 个来源的跑马带卡片共用同一份
///   默认封面（见 HomeView.swift `RailMarqueeCardView`）。环的几何、
///   开环触发（只剩平面带横向拖动）、收回、变暗一律不动。
///
/// r31-marquee（用户 2026-11-21 06:25「跑马带里的卡片现在是卡着的，
/// 不会一直向左滑」）：本文件只动 `FlatDisplayLinkProxy` 一处——
/// 回调不再经 `Task { @MainActor in }` 跳主线程（display link 已挂在
/// RunLoop.main 上，回调本身就在主线程；每帧一个 Task 让步长在任务
/// 队列里扎堆，就是「一卡一卡」，dt 还是在 Task 里读的 link.timestamp）。
/// 改成代理直接调 tick（`MainActor.assumeIsolated`，link 只加在 .main 上）。
/// 每日带卡住的嫌疑逐项核过，都不是：flatDragging 出口齐全（ended /
/// cancelled / failed / willMove / touchesCancelled）+ 10s 看门狗，
/// 收回竞态封死（收回进行中没有任何调用能再推 closeGeneration、
/// closeRing 的完成任务 void 不掉），flatDwellUntil 只在曲目 id 集合变
/// 了时重停（切歌不重停），flatSetWidth 由偏好重报恢复——每日带没有能
/// 永久卡住的旗子；真正能永久卡住的是 rail 驱动的 isDragging（只
/// 有 onEnded 一个出口，见 HomeView.swift），硬停修在那边。
/// 速度 24px/s、dt 夹 0.1s、回卷归一化、初画 2.5s、松手 1.2s、10s
/// 看门狗一律不动。驱动见 verification/r31-marquee.cjs。
///
/// r31（2026-11-21，真圆柱，用户 06:23 追问「前面是折叠效果对吗」——
/// 对，前面那个看着就是折叠，不是转圈圈）：
/// - 根因（三处，全在 ringLayer + 几何函数里）：
///   ① 平的：卡片只用 x = centerX + r·sin(world) 定横向位置，所有卡都在
///      z=0 一个平面上，没有 z 方向深度——不是推出到圆柱面上的槽位。
///   ② 转反了：卡片 `.rotation3DEffect(-world°, Y 轴)` 是从播放页 CoverFlow
///      抄来的朝内转法（右卡 -40°，右缘朝前、左缘朝后，像翻书一样折向
///      中心）；套壳圆柱槽位是 rotateY(+base) translateZ(R)，卡面切于圆柱面
///      朝外（右卡左缘近、右缘远，绕着圆柱往后收）。r20 文件头就写过
///      「照抄播放页 CoverFlow」是环几何错的根源之一，旋转符号是同一处
///      抄错留下来的尾巴。
///   ③ 透视错了：卡片旋转与容器都用 SwiftUI perspective 0.5 强透视，
///      压扁程度远超套壳的 P=3.2R（标准档约 697pt），近缘放大、远缘缩小，
///      折叠感就是这么来的。
/// - 改法（只动本文件）：卡片按真圆柱投影——z = R·(cos(world)−1)
///   （`cylinderZ`，正前方 0、侧卡为负，推出到圆柱面上）；透视距离
///   P = max(3.2R, 520)（`ringPerspective`，壳版 openRing 原式）；横向
///   x = R·sin(world)·P/(P−z)（`projectedX`，透视除法把侧卡往中心收，
///   r30 的 x = R·sin(world) 没除透视，侧卡摆得太开）；缩放与横向共用
///   同一个透视因子 P/(P−z)（`perspectiveFactor`，`depthScale` 改成
///   按 world 角委托给它，旧的 3.2/(4.2−cos) 就是同一式子展开后的样子，
///   数值不变）；卡片旋转改成 +world（切于圆柱面朝外），透视参数改成 0
///   ——卡内透视不由 SwiftUI 的 0.5 再算一次，全程只走显式 3.2R 投影
///   （SwiftUI perspective 与 CSS perspective:px 没有精确等价换算，
///   见 CoverFlowView 文件头诚实注；卡内梯形透视是已知残留：正交旋转下
///   侧卡 apparent 宽约 106pt，真投影约 90pt，远缘多出约 11pt，见驱动）；
///   容器整体 rotateX(-5°) 删掉——相机 -5° 已由每卡 `tiltDrop` 表达
///   （r26-3D 视频实测公式），容器旋转是双算，还把 0.5 强透视带进来。
/// - R（r35 改回壳版，见驱动 §R2–§R5）：r31 的「视频实测 pitch≈卡宽」
///   已被用户 2026-11-21 真机报告推翻——环开着拖动旋转时相邻卡几乎相贴。
///   f_050 量到的约 3px 间隙是静止展开态的一帧，不是拖动中的常态：
///   旧 pitch（=卡宽 149pt、R≈218pt）下静止间隙只有 2.9pt，拖到两槽
///   中途（world ±20°/60°）相邻卡重叠约 11pt——卡就是贴着转的。
///   改回壳版 openRing 原式：pitch = 卡宽×1.14（标准档 169.86pt），
///   R 取弦长公式 pitch/(2·sin20°) ≈ 248pt，cap = round(2πR/pitch)
///   = 9，step = min(360/9, 2·asin(pitch/(2R))) = 40°，P = 3.2R。
///   新 pitch 下静止间隙约 21pt、拖动中途中心对约 29pt、远端对也不
///   相贴（约 1.7pt，见驱动 §R4–§R5 镜像）。Rview 那条路不用：套壳
///   Rview = (vw/2−14−cardW/2)/0.762 是按 94pt 小卡算的，配 149pt 卡
///   只给 R≈144pt，弦长 125pt < 卡宽，相邻卡反而重叠——原生卡是
///   0.382vw 不是套壳的 0.24vw，弦长 R（248pt）才是决定可见间隙的
///   那一个；侧卡溢出屏边本来就不裁（r31 已定），Rview 的屏内约束
///   不适用。只动 pitch/R/step/cap/P 这一组几何量，压暗、后仰、位置、
///   绑定、跟手、惯性一律不动。
/// - 面板裁切作废（r30 v5 图口径）：f_050/f_060/f_070 里侧卡都溢出面板
///   到屏边（左卡亮区从 x=0 起、右卡切到 720px 屏边），环层改全屏宽、
///   不 clip，命中测试同步删面板外拦截、改用 projectedX + panel.centerX
///   （旧 hitTest 还拿 screenWidth/2 当中心，与渲染的 panel.centerX
///   不是同一个锚点，顺手改掉）。
/// - 不动：跟手 perPixel、110ms 采样 ±1400°/s、τ=1.08s 投影 + 弹簧 118
///   吸附、只露正面、收回时机、一次 3 张、展开手势（跑马带左右拖动）、
///   环锚点 = 跑马带中心（r31 前半段）。驱动见 verification/r31-ring.cjs §8–§11。
///
/// r33（2026-11-21，7.49s 新视频 ~/workspace/user/media_library/video/c3/
/// c3dd1514…1a40.mp4，720×1566/30fps，逐帧 /tmp/ring-frames/f_001–f_030，
/// 4fps；只修环的 5 条 + 用户 10:11/10:12 补的两条联动/过渡要求）：
/// 逐帧实测（f_002/f_010/f_020/f_030 量取，360pt 坐标）：
/// - 中心卡宽约 124pt，侧卡约 86–100pt（比值约 0.71 = cos40°×0.93，
///   旋转与透视缩窄本身在起作用）；侧卡亮度只比中心卡低约 7%（壳版 flat
///   shade 在 40° 只有 3.8%）；三张卡顶边齐平、无梯形、无渐变明暗——
///   肉眼就是三张平铺窄矩形。底部 94% 高度处 30 帧全无提示字
///   （y720–748 亮像素 0）；本地音乐文件夹副标题行（y758–765）倒是有一行
///   「空文件夹 拖动旋转 · 点击播放 · 松手收回」，且 f_001（环闭合、
///   覆盖层根本没挂）里一字不差——视频机型上的那行是静态页内容，
///   不是覆盖层提示，与 r28–r32 全部快照对不上（快照里副标题只有
///   「空文件夹」，提示只在覆盖层里）：视频 build 不是任一归档源码编的，
///   见交回；源码侧副标题已是干净的，不动它。
/// - 封面：f_001–f_008 大多有真封面，f_010 起灰占位越来越多，
///   f_014–f_030 基本三张全是浅灰音符占位（白底 CoverImageView 占位经
///   变暗后读作浅灰，不是深色 DefaultCoverArt）。
/// - 环 0.25s 打开、转到 7.25s 没收（7 秒约 30 首）；f_001→f_002 一跳切过去。
/// 1. 3D 形态（本轮）：cylinderZ / ringPerspective / projectedX 一直在
///    环卡上起作用（实测侧卡 0.71 倍窄就是它们算出来的），丢的不是几何量、
///    是视觉线索——正交旋转没有梯形、flat shade 只有 3.8%。修法：
///    rotation3DEffect perspective 0 → 卡高/P（≈0.28，三档 0.27–0.29；
///    SwiftUI perspective 是相对量、与 CSS px 无精确换算，0.5 已远超 P，
///    0.28 是按卡高换算的近似值，真机确认梯形强度）；压暗改沿卡面横向渐变
///    （近缘 0 → 远缘 `shadeFarEdge`，40° 槽位远缘 0.42，中心卡不压暗；
///    壳版 3.8% 原值留作 `shadeOpacity` 对照）。旋转符号 +world、
///    depthScale、projectedX、cylinderZ、一次 3 张、53%–71% 卡位、
///    整页约 45% 变暗一律不动。
/// 2. 封面（本轮）：根因不是门卡住——CoverFetchGate（Proxies.swift）max 4
///    并发、FIFO、抛错/取消都还槽，工作正常；是吞吐追不上转速：门约 2 张/秒，
///    环约 4.3 张/秒，7 秒转 30 首、每首只露约 0.7 秒，封面 1.5 秒+ 才到，
///    且平面带挂载时就把全单 2n 张取图推进了门（同 URL 去重，顺序就是单序），
///    环转到没取过的曲目就是占位。修法（只动本文件 + CoverImageView）：
///    开环 + 中心槽位每变一次预取前后各 5 槽（`prefetchRingCovers`，
///    每 URL 一个 detached 任务分头起取，不串行等）；环卡占位改深色
///    （CoverImageView 新增 `darkPlaceholder`，默认 false 其余调用点不动，
///    RingCardView 传 true；coverURL 为 nil 时本来就是深色 DefaultCoverArt）。
///    冷页一次转 30 首仍会跑赢 4 并发门，见交回残留（提门限是 Proxies.swift
///    的事，不在本轮文件范围里）。
/// 3. 松手自动收（本轮）：视频本身坐实不了定时器坏——7 秒一直在拖，
///    ringDragging=true 时 hold-close 的守卫本来就不该收；视频结束时离最后
///    一次动作只有 0.24 秒，不到 1 秒保持期。代码查下来的真缺口是两条
///    卡住路径（都只动覆盖层触摸层 + 一个模型方法）：① 手指落下（touchesBegan
///    取消了待执行的收回）→ 晃 <5px → 抬手：pan 认出来了 tap 不触发、
///    dragStarted 又是 false，handlePan .ended 什么都不干，环永远开着
///    （补 `ringTouchEnded` 重排 1s 收回）；② 系统取消触摸（来电/锁屏/
///    控制中心）时覆盖层没有 touchesCancelled 兜底（平面带有，覆盖层没有），
///    同样断定时器（补 override，拖起来了走 ringDragEnded，没拖起来走
///    ringTouchEnded）。scheduleHoldClose 本身（1 秒 + 代号守卫）不动。
/// 4. 底部提示（本轮）：覆盖层提示从 VStack + Spacer + padding(.bottom,
///    max(16, safeArea+10)) 改成按屏高 94% 定死的 `.position`
///    （safeAreaInsets 在 ignoresSafeArea 的 GeometryReader 里读到 0 时
///    只垫 16pt，提示沉到约 97%、贴 Home Indicator）；本地音乐文件夹
///    副标题源码已是干净的「空文件夹」/「N 首」（LocalMusicView.swift:64，
///    r28–r32 快照一致），本轮不动它，视频 build 与归档源码不符见上面实测。
/// 5. 展开跳变（本轮，与用户 10:12 第 2 条同一件事）：根因不是动画参数——
///    520ms easeOutQuint / 430ms / 变暗 0.26s 的参数一直是对的；是提交时序：
///    openRing 里 phase=.open 与 entryT=1、overlayOpacity=1 在同一个同步块里，
///    覆盖层首帧就是最终值，动画一次插值都不跑（f_002 在 0.25s 已满尺寸满变暗
///    不是动画跑得快，是动画根本没跑）。修法：动画延后一显示帧
///    （Task.sleep 16ms，entryGeneration 守卫；不能复用 closeGeneration，
///    ringDragEnded/ringTouchBegan 也会 +1，会误杀还没跑的展开动画），
///    首帧 entryT=0/opacity=0 先上屏、随后 520ms 逐帧展开；变暗 0.26s
///    跟同一批跑。收回不用改：closeRing 时覆盖层已挂着
///    （HomeView 挂载条件是 ringPhase != .closed，open 与 closing 都挂），
///    closeT/overlayOpacity 有 from 态，430ms/220ms 插值正常跑。
/// 联动（用户 10:11/10:12 第 1 条，环跟着下面那排卡片走）：r51 已按套壳
/// 逻辑拆掉——拖动环时带子不再实时跟过去（`syncFlatOffsetToRingCenter`
/// 已删），环收回后带子从旧位置接着滚；开环锚点仍是在播曲目/手指卡
/// （用户 22:33 定稿），不动。
/// r33-marquee 的修补（syncInputs 带宽兜底、flat 看门狗 Timer、
/// startFlatWatchdog）一字不动；HomeView.swift、HomeViewModel.swift、
/// NativeBridge.swift、PlayerView.swift、Apple Music 相关文件一行不动；
/// verification/*.cjs 不动（驱动由协调员写）。
///
/// r34（2026-11-21，用户 11:35 视频 ~/workspace/user/media_library/video/a2/
/// a21ebe53…94cc4.mp4，720×1566/30fps/12.4s，关键帧见
/// verification/r35-ring-evidence/NOTE.md；只动本文件，HomeView.swift
/// 一行不动——环的位置/接线都在本文件内解决）：
/// 1. 平带卡死（r33 第 2 件第二次被证伪）：视频逐帧量过（相位相关 +
///    竖直锐边追踪，三法一致）：环闭合窗口 0–2s、6.5–8s、11.5–12s 里
///    平带净位移 0±25px，而 24px/s 应走 44px/0.5s、2s 窗口走 88px——
///    带子是冻住的，不是慢。代码里逐项钉死：
///    - 速度不是 0（marqSpeedPxPerSecond 默认 24，公式见 HomeViewModel）；
///    - dwell 不是反复重置（DailyTrack.id 就是平台 id，稳定；loadDaily
///      只跑首加载 + 切平台，notePlayed 不碰 daily；syncInputs 只在
///      id 集合变了时重停——没有每 2.5s 一次的重停源）；
///    - 模型不是反复重建（HomeView 一个 @StateObject，RootView switch
///      身份稳定；重建只发生在切页往返，重建后 onAppear 会重新 sync）；
///    - setWidth 不是 0（syncInputs 兜底 + 偏好上报都是 n×(卡宽+间距)）；
///    - 剩下两条是真缺口（都在看门狗里）：① r33 的看门狗号称“清拖动旗”，
///      但 `flatDragging = false` 写在 `guard !flatDragging …` 之后——
///      旗子卡住时守卫先 return，清旗那行永远到不了，看门狗救不了
///      恰恰是它要救的那种卡死；能清旗的只剩 tickFlat 里的 10s 超时，
///      而它要 display link 在跑。② 两条驱动（link + 看门狗 Timer）
///      共用一个启动点（syncInputs → startFlatTimer）与同一套五项守卫，
///      link 一死、旗子一卡就是永久冻住，没有第二条独立的命。
///    修法（只动本文件）：看门狗改成独立驱动——先查 link 存活
///    （1s 无回调就地重建 link），再清卡住的旗（3s 无触摸活动就清，
///    清旗在守卫之前），最后才是守卫 + 该走不动时自己推一步；
///    每次卡住都把五项守卫的实测值 + dwell 最后一次重停原因写进
///    DiagLog（下次再报“不动”，日志直接报是哪一项拦的，不用再猜）；
///    setWidth 兜底从 `== 0` 改成 `< 一份宽度`（偏好先报 0 会把宽度
///    写成 0+16=16，旧的 `== 0` 再也修不回来，带子只能在 16pt 里打转）。
///    速度 24px/s、dt 夹 0.1s、初画 2.5s、松手 1.2s、10s 看门狗一律不动。
/// 2. 3D 环位置（视频实测：环盖中心约 927px/502pt，平盖中心约
///    1145px/620pt，差约 118pt；按旧锚点 cy = stripCenter 推算只差
///    23pt——锚点本身就有问题）：根因两层——① 环卡按 VStack 中心摆，
///    盖面中心比卡中心高 23pt，平盖中心比带中心低 26pt，旧锚点
///    cy = stripCenter.y 自带 23pt 上偏；② stripCenter 是存下来的
///    CGPoint（偏好上报），实测环盖位置对得上 fallback 屏高×0.62
///    （523pt，差 33px）或默认 Hero 下的旧值（475pt，差 56px），
///    对不上活的 stripCenter（637pt，差 243px）——存下来的锚点在
///    真机上就是不可信（三种候选都落在量取误差内，见交回，没坐实是哪一种）。
///    修法：环不再用存下来的锚点——环层搬进平带容器里（见第 4 件），
///    卡位全部用带内局部坐标算（盖面中心对齐公式见
///    `ringCardCenterYLocal`），存下来的 stripCenter 只剩变暗中心与
///    点按命中用（偏一点只影响光晕与边缘点按，不再决定卡在哪）。
/// 3. 3D 形态（按 ring.js 一比一，不再近似）：① 压暗只盖封面是错的——
///    壳版 `.mring__shade` 是 `inset: 0` 整卡覆盖（封面 + 歌名行），
///    原生侧卡的歌名行还是全亮白字，整张卡读不出暗。修法：整卡再盖一层
///    壳版公式的平色压暗（0.55·((1-facing)/2)^1.25，40° 时 3.8%），
///    封面远缘渐变（r33 的 0.42）保留，两层叠加。② 相机 -5° 只有纵向
///    下坠（tiltDrop），卡面本身没有后仰——壳版相机是
///    translateZ(-R) rotateX(-5°)，卡面也要跟着后仰 5°。修法：Y 轴
///    旋转之后再加一道 -5° X 轴旋转（perspective 0，只取朝向、不叠透视）。
///    ③ 透视不改值：ringCardPerspective = 卡高/P（P = 3.2R）一直就是
///    从 P 派生的，不是猜的 0.28；位置（projectedX）与缩放（depthScale）
///    也一直是壳版投影公式原样——视频里卡位与宽度比（侧卡约 0.71 倍）
///    本来就对得上，丢的是压暗覆盖与后仰，不是几何量（见驱动 §8）。
///    一次 3 张、槽距 40°、R 弦长公式、只露正面（facing 0.06/0.30）不动。
/// 4. 3D 跟歌曲绑定（最关键）：旧结构是两个组件——平带（HomeCoverRingView）
///    与环浮层（HomeRingOverlayView 里的 ringLayer），环的位置、内容、
///    生命周期都另起一套，只靠一个存下来的 stripCenter 与带子对齐，
///    对不上就飘走（第 2 件就是这么来的）。修法：环层搬进平带容器
///    （`flatStrip` 里的 `ringLayerInStrip`），与平带共用同一份
///    model.tracks、同一套 visibleSlots/angle/anchorIndex、同一个容器——
///    平带与环是同一份歌曲列表的两种状态：环闭合时是平带（自动滚），
///    环打开时同一批卡在原地起圆柱（盖面中心与平带盖面中心重合，
///    entryT 0→1 只长尺寸、不挪位置）；覆盖层只剩变暗 + 底部提示 +
///    触摸层，不再画卡。平带裁切（`.clipped()`）只留在平带容器上，
///    环开着时不裁——侧卡可以溢出带子、贴到面板边（实拍侧卡本来就
///    溢出面板到屏边，r31 已定；面板圆角裁切仍在，环开时侧卡外沿
///    最多被面板切掉约 5pt，见交回残留）。
/// 不动：环开/转/收、底部提示「拖动旋转 · 点击播放 · 松手收回」、
/// 展开 520ms/收回 430ms/点空白 220ms/松手 1s 收、惯性 τ=1.08s +
/// 弹簧 118 吸附、点卡播歌收回、下滑 >90px 退出、变暗三档。
/// 驱动见 verification/r34-ring.cjs。
///
/// r35-8（2026-11-21，用户 19:07「修复 3d 滑动的时候像把卡片丢掉的拖影」，
/// 19:08「只需要像个圆柱体一样一直转动就行」「看看套壳版」）：
/// 根因钉死：`visibleSlots()` 只取中心±1 格，槽位在 world ±60°
/// （facing 0.5、透明度 1）时硬弹出/消失——拖动中每转 40° 就有一张
/// 全不透明的卡在屏内凭空消失、对面凭空出现一张，看着就像把卡片甩出去。
/// 平带重影已排除：环开着时平带透明度 = 1 - overlayOpacity = 0，拖动里
/// `syncFlatOffsetToRingCenter` 只动看不见的带子；文件里没有 rasterize /
/// .drawingGroup / .blur，拖动路径上也没有 .animation（没有动画滞后/过冲）。
/// 修法：窗口放回中心±2（r31 由 ±2 收成 ±1 的那次改动作废），槽位进出
/// 发生在 |world| = 86.5°（facing 0.06、透明度 ≈ 0）处，再经 0.06–0.30
/// smoothstep 淡入/淡出——套壳 ring.js 9 槽固定身份绕圆柱转同款；
/// 静止时边缘多两张约 0.46 透明度的淡卡（壳版同款）。拖动 1:1 /
/// 松手惯性 + 弹簧 / pitch / 压暗 / 后仰 / 位置 / 绑定一律不动。
/// 驱动见 verification/r35.cjs §O。
///
/// r36-8（2026-11-21，用户 21:31 原生视频 + 21:32 套壳视频「你好好看
/// 套壳版的」：逐帧对比后按五项修——亮度/位置/卡片数/透视/顺滑。
/// 视频：原生 ~/workspace/user/media_library/video/32/321205c7…1cac.mp4
/// （8.3s，帧 ~/workspace/ring-video-frames/f001–f033，4fps）；
/// 套壳 ~/workspace/user/media_library/video/7e/7ed8a9f8…7a0e.mp4
/// （12.5s，帧 ~/workspace/ring-shell-frames/s001–s038，3fps）。
/// 量取（640×1392 文件坐标，PIL 亮度均值/90 分位；数字进驱动 §H）：
/// 1. 亮度：环带 P90（最亮一档 ≈ 卡面）壳版约 155、原生约 56（2.8 倍）；
///    同曲《回到你身边》壳版卡面 135、原生 45（3 倍）；顶栏壳版 53–56、
///    原生 19.5；本地音乐行壳版 42、原生 28。壳版开环/闭合比：顶栏
///    ×0.45、本地行 ×0.34（压暗比与原生一致，绝对差来自面板底色——
///    壳版浅绿面板闭合 117、原生专辑取色深场约 40）。
///    根因（两处，都是层级不是数值）：① 壳版压暗是 `.mring` 的背景，
///    卡片是它的孩子、画在压暗上面，卡片根本不被压（只剩 0.038 shade）；
///    原生压暗层在覆盖层里、盖在环卡上面（卡在页里、压暗层在覆盖层里），
///    中心卡先被 ×0.64；② r33 的远缘渐变 shadeFarEdge（40° 时 0.42）
///    是 11 倍于壳版的压暗（壳版 flat 公式 40° 时 3.8%）。
///    修法：压暗层在环卡带上开洞（scrimHoleMask：活的带子矩形、上下
///    16pt 羽化，洞里卡片全亮、洞外页面照常压暗；r34 的环在带子里的
///    绑定不动，不把环搬回覆盖层）；删 shadeFarEdge/shadeGradient，
///    只留壳版 flat 公式 shadeOpacity；删拖动顶部加暗层（0.14 黑，
///    壳版 ring.js 里没有，壳版视频拖动中 Hero 亮度与静止时一样）。
///    压暗三档 0.36/0.58/0.78 不动——已比壳版 CSS 的 0.40/0.70/0.88
///    轻，页面的压暗比实测与壳版一致（×0.45/×0.34），重的不是数值。
/// 2. 位置：顶栏底→环顶壳版约 133pt、原生约 110pt，环偏高 23pt、
///    贴着顶栏；壳版环中心约 60% 屏高（ring.js --my 默认 60vh）、
///    原生约 55%。修法：带子容器顶加 stripTopInset = 24pt（平带与环
///    一起下移，r34 绑定不动；面板封顶账里有约 36–43pt 余量，不顶出
///    提示行；搜索块里的同一视图也跟着下移 24pt，账见交回）。
/// 3. 卡片数/透视：实测壳版卡间距 241 文件像素 ≈ 原生 projectedX(40°)，
///    卡宽也一致——pitch = 卡宽×1.14、R = 弦长公式 248、cap = 9、
///    step = 40°、P = max(3.2R, 520)、perspective = 卡高/P，
///    六个数本来就是 ring.js 公式原样，一字不动。「只露 3 张」不是
///    几何数错，是亮度：原生 ±80° 的两张边卡是 21pt、0.44 透明度
///    的暗条，糊在全黑底上看不见；壳版同位置的边卡是亮的。亮度修好
///    后边卡重新可见，静止 3 大 + 2 边、拖动中 4–5 张，与壳版一致；
///    侧卡「太平」同理——0.42 远缘渐变把梯形盖死了，删掉后梯形
///    （perspective 卡高/P）重新可见。visibleSlots 仍是中心±2、
///    |world| ≤ 86.5°（r35-8 的拖影修法不动）。
/// 4. 顺滑：拖动本身 1:1 是对的（ringDragMoved 直接写角、无量化、
///    无 .animation，HomeView 里也没有对 angle 的 animation；
///    visibleSlots 换槽发生在透明度 ≈ 0 处，r35-8 已钉死）——顿挫
///    在两处：① 松手弹簧是 SwiftUI `.spring(response: 0.58,
///    dampingFraction: 1.0)`，只对上了频率（2π/√118 ≈ 0.58s），
///    吃不到初速度——松手先死停再爬过去，与壳版「带着速度飞过去
///    再稳稳停住」不是同一种手感，且不是 1/240s 积分；② 每步触摸
///    都写 angle（@Published，全模型观察者重算）+ onChange 再同步
///    一次带子，渲染一超 16ms 就丢帧、中间角被跳过去，看着就是丢包。
///    修法：松手改走显式弹簧驱动（startRingSpring/ringSpringFired：
///    CADisplayLink + 1/240s 子步半隐式欧拉，stiffness 118、阻尼
///    2√118、初速度 v 直接带进、停稳条件与壳版同款；新拖动上手先
///    停弹簧，收回/释放时停表）；拖动 1:1 公式、110ms 采样、±1400
///    限幅、τ=1.08s 投影目标一字不动。
/// 驱动见 verification/r36-ring.cjs（§A–§G 断言 + §H 实测证据）。
/// 诚实残留见交回（顺滑与亮度须用户真机录屏确认；浅色专辑时卡缝
/// 比壳版亮一档；SwiftUI perspective 与 CSS px 无精确换算）。
///
/// r39-4（2026-11-22，第 4 件，定稿 ~/workspace/lizi-r39-home-cards-mockup.png，
/// 居中版）：首页卡片下面加歌名 + 演唱者——只加这两样，不加专辑名；
/// 卡片里面只有封面，文字在封面下方；歌名 16pt 粗体、演唱者 14pt，
/// 居中对齐卡片；卡片大小一点不动（卡宽 180/190/209、卡高、间距 16 不动；
/// r38 的横屏卡宽封顶 100pt 已作废，不搬）；卡片都在同一条平行线上，
/// 只有点中的那张整体上抬 1pt（0.18s 动画；r43-3：第 3 件 6pt → 1pt）。
/// 做法：`coverOnly` 不再藏卡下两行字（只剩封面未显示时的占位开关），
/// `flatHeight` 恒为卡宽 + 52 + 1（两行字高 + 上抬顶空；52 是 r37-1 前
/// 就有的旧值，面板封顶 flatCard + 217 本来就含这 52pt 空位，面板高不动），
/// `selectedFlatIndex` 记点中的卡；环盖面/命中盒跟 +1 顶空走（r43-3）
/// （`ringCardCenterYLocal` / `ringCardCenterScreenY`）；其余 4 栏 +
/// 排行榜目录的 rail 卡见 HomeView.swift `RailMarqueeCardView`。
/// 3D 环卡（`RingCardView`）、入口提示行、点按/开环/收回一律不动。
///
/// r39-5（2026-11-22，第 5 件，r38 第 9 件规格原样照做 + 用户新补两条；
/// 定稿图 v2 ~/workspace/lizi-r38-3d-ring-v2-mockup.png）：
/// 环卡与全部几何按壳版 ring.js openRing 1:1：cardW = clamp(vw×0.24, 84, 112)、
/// cardH = cardW+28（壳版一行歌名；原生环卡两行故 ringCardHeight 仍 +46，
/// 只取壳版封面宽）、pitch = cardW×1.14、R = max((vw/2−14−cardW/2)/0.762,
/// cardW×0.8)、P = max(3.2R, 520)、cap = clamp(round(2πR/pitch), 7, 64)、
/// step = min(360/n, 2·asin(pitch/(2R)))、perPixel = 180/(πR)×1.45；
/// vw 是调用方同步进来的实测屏宽 `screenWidth`（HomeView 外层 GeometryReader
/// 的 outer.size.width，歌单详情页是 contentView 的 GeometryReader），
/// 0 = 调用方没传，回落旧 tier 分档（环卡 141/149/164、step 40°、R 弦长公式）。
/// 平面卡宽不动（r38-8 的 ⌊(带宽−2×16)/3⌋ 与横屏封顶 100pt 不搬，
/// flatCard 仍是 tier 分档 180/190/209）。
/// r43-1：第 1 件——横屏平面卡改 0.181×vw（874pt → 158pt），竖屏仍 tier 分档；
/// 环卡按横竖屏取 0.246/0.393×vw（见 ringCardWidth），screenHeight 与 screenWidth 同路透传。
/// r44（第 3 件）：竖屏环卡 0.393→0.398×vw（排行榜竖屏实测 160pt，全模式统一），
/// 横屏 0.246×vw 不动；pitch 1.14→1.40、R 除数 0.762→0.42（见 ringPitch /
/// ringRadius），竖屏 D≈178pt（间隙 +18pt）、横屏 D≈249pt（间隙 +63pt）。
/// 触发（r40：改回 r24）：平面带横向拖动开环（10px 内不判方向；
/// 竖向占优 |dy|>|dx|×1.25 才交还 ScrollView，上/下都一样）；
/// r39-5 的上滑开环 + 横向手滚跑马带（flatOffsetX 1:1 跟手）作废。
/// 平时跑马带 24px/s 自动向左走；
/// 拖动转环、松手惯性 + 弹簧吸附、点卡播歌、点空白/松手 1s 后收回、
/// facing ≤0.06 藏 / 0.06–0.30 smoothstep 淡出一律不动。
/// 点中的环卡整体上抬 1pt（0.18s 动画，`selectedRingIndex`，与平带卡
/// `selectedFlatIndex` 同款；点环卡播歌后环收回，上抬在 430ms 收回淡出里可见）。
/// 用户新补：转动时全部卡片保持一条线——环卡纵坐标不再按 facing 各偏
/// tiltDrop（旧：侧卡比中心卡高约 4.7pt），全部取中心卡同一纵坐标
/// （`ringCardCenterYLocal` / `ringCardCenterScreenY` 不再读 world 角；
/// 相机 -5° 只剩卡面后仰那道 X 轴旋转，`tiltDrop` 随之删掉）。
/// visibleSlots 窗口按角度算（span = ceil(86.5/step)，step=40° 时与旧 ±2 同集）；
/// 只有一张卡时不转（angle 钉 0、直接排 1s 收回，壳版 releaseRing n≤1 分支）；
/// 收回时覆盖层透明度与 closeT 同曲线（timingCurve(0.32, 0, 0.67, 0)，
/// 壳版 1 − easeInCubic(closeT)；旧 .easeOut 先快后慢、与壳版反向）。
/// 入口提示（r40：改回横向拖动口径，「左右拖动展开 3D 环 · 拖动旋转」，
/// arrow.left.and.right 图标；旧的上滑口径已删）。
///
/// r51（2026-11-23，第 1 件 + D5，3D 跟随按套壳逻辑改，只动本文件）：
/// 拆掉原生 r33/r47-2/r48-3 自加的三条跟随链，改回套壳语义（套壳
/// public/m/ring.js：只有 Hero 跟歌、在播卡打高亮、跑马带 24px/s 自滚；
/// 环锚点是手指那张卡；环内点卡播歌后 close('play')，finishClose
/// 只设 flat.resumeAt = now()+220ms，带子从旧位置接着滚、不居中；
/// 切内容 setItems → resetFlat 从头显示）：
/// - 删 `centerFlatOnSelected` 函数 + 两处调用（syncInputs 跟随块、
///   playTrack 点卡居中）：点卡只写 selectedFlatIndex（上抬/高亮标记），
///   不动 flatOffsetX；
/// - 删 syncInputs 的 r48-3 跟随块（切歌不再写 flatOffsetX、不再留
///   2s dwell；`selectedFlatIndex = playingIndex` 的 r45-3 标记保留，
///   只标记不动位置；内容换了仍 flatOffsetX=0 从头显示）；
/// - 删 `syncFlatOffsetToRingCenter` 函数 + 三处调用（ringDragMoved、
///   ringDragEnded 末尾、覆盖层 onChange(of: angle) 弹簧阶段）：转环
///   只转环，带子停在旧位置；r46-5 的高亮跟环中心走随之作废，高亮只跟
///   在播曲目；
/// - 收环 dwell：closeResumeMs 2000 → 220ms（壳版 finishClose:653 同款；
///   松手恢复 resumeMs=1200 对照壳版 ring.js:57 RESUME_MS=1200，不动）。
/// - D5：删 `centerCardIndex()`、`isRingDragging`（无读取方）、
///   `panelRect` 的 halfWidth、`ringCenterY`/`hitTestRingCard` 的
///   topEdge 参数（体内 `_ = topEdge`）；RingTouchView 自带的 topEdge
///   属性不在 D5 范围内，保留。
/// - 不动：Hero 跟歌、平面带 24px/s 自滚、开环锚点（playingIndex 优先、
///   手指卡回落，r26-3D 用户定稿；本轮拆清单未列锚点，未改）、点卡播歌、
///   r47-4 正在播放模式置顶（在 HomeView/HomeViewModel，不在本文件）、
///   r50 三件、其他切歌逻辑；显示原样不动，只修跟随语义。

// MARK: - r43-2：通用环卡（第 2 件，首页全模式适配 3D）

/// 环上的一张通用卡：封面 + 标题 + 副标题 + 点按行为（复用
/// HomeView.swift `RailMarqueeCard` 的 id/coverURL/title/subtitle/onTap，
/// 点按原样透传——曲目照旧 setQueue、歌单/专辑照旧面板内打开或进详情、
/// 电台照旧进详情；从 rail 卡转过来走 `RailMarqueeCard.ringCard`
/// （HomeView.swift，`RailMarqueeCard` 是 HomeView 的 private 嵌套类型，
/// 本文件看不见它）。
/// 为什么是“模型里并行一条通用路”，而不是把 [Track] 全换成它：
/// 曲目路的点播要在点按当下才拿得到 PlaybackStore + queueTitle +
/// preservePlayNext（`playTrack(at:store:)`），sync 时建不出 onTap 闭包；
/// 全换会动每日/正在播放/榜单详情/歌单详情四路的同步与点播代码。
/// 并行路只加不改：`genericCards == nil` 时模型走的仍是旧曲目路
/// （同一份 setQueue、同一份 playingIndex 锚点、同一份预取），
/// 下面 `itemCount`/`itemIDs`/`itemCard(at:)` 在曲目路下与旧
/// `tracks.count`/`tracks.map(\.id)`/`tracks[i]` 同值。
struct HomeRingCard: Identifiable {
    var id: String
    var coverURL: URL?
    var title: String
    var subtitle: String
    /// 点按行为（调用方填；曲目路合成的卡不填，点播走模型旧 `playTrack`）。
    var onTap: (() -> Void)?
    /// VoiceOver 标签：曲目路合成时填「播放：标题」，与旧 `FlatRingCard` /
    /// 环层同值；rail/榜单卡填标题本身（点按不是播歌，是打开/进详情）。
    var accessibilityLabel: String

    init(id: String, coverURL: URL?, title: String, subtitle: String,
         onTap: (() -> Void)? = nil, accessibilityLabel: String? = nil) {
        self.id = id
        self.coverURL = coverURL
        self.title = title
        self.subtitle = subtitle
        self.onTap = onTap
        self.accessibilityLabel = accessibilityLabel ?? title
    }
}

// MARK: - 状态机

/// 首页环的状态机：平面跑马带 + 全屏圆环共用一份。
///
/// 手势入口有两处（同一根手指可以不断开）：平面带上的横向拖动（展开后继续拖
/// 就是转环，r24 同款）与覆盖层上的直接拖动；两处都调
/// `ringDragStart` / `ringDragMoved` / `ringDragEnded`。
@MainActor
final class HomeCoverRingModel: ObservableObject {
    enum RingPhase { case closed, open, closing }

    // MARK: 输入（HomeCoverRingView 从调用方同步进来）

    @Published var dailyTracks: [Track] = []
    /// r43-2：第 2 件——通用卡路（rail 四栏 + 榜单目录）：调用方经
    /// syncInputs(cards:) 同步进来；nil = 曲目路（旧行为，一字不动）。
    /// 点按走各卡自带的 onTap（调用方填好的原行为），不走 setQueue。
    @Published var genericCards: [HomeRingCard]? = nil
    /// 在播曲目的身份键（`platform:id`；r26-3D 开环锚点用，不驱动渲染，
    /// 故不用 @Published；调用方经 syncInputs 同步 playback.currentTrack）。
    var playingKey: String?
    // r51：第 1 件——lastFollowedPlayingKey 已删：它只为 r48-3 跟随块服务，跟随块已拆（见 syncInputs），不再记。
    @Published var isLoadingDaily = false
    /// 每日推荐 spinner 是否可见（r35-9，P0-2：250ms 后仍未回来才亮；
    /// 视图只认这面旗子亮 spinner，不认 isLoadingDaily）。
    @Published var dailySpinnerVisible = false
    @Published var dailyEmptyReason: String?
    @Published var marqueeSpeed: CGFloat = 24
    @Published var tier: PlayerTokens.PlayerSizeTier = .standard
    /// r39-5：第 5 件起调用方同步进来的实测屏宽（HomeView 外层 GeometryReader
    /// 的 outer.size.width；全屏环覆盖层与壳版 window.innerWidth 同值）。
    /// ringCard / ringStep / ringRadius 全从它现算（横竖屏各按自家屏宽算）；
    /// 0 = 调用方没传（歌单详情页那路以外不应出现），回落旧 tier 分档，
    /// 那路尺寸不动。flatCard 竖屏不读它（r43-1：横屏时 flatCard = 0.181×vw，见该函数）。
    @Published var screenWidth: CGFloat = 0
    /// r43-1：第 1 件起调用方同步进来的实测屏高（与 screenWidth 同路，
    /// HomeView 外层 GeometryReader 的 outer.size.height；歌单详情页是
    /// contentView 的 GeometryReader）。只用来判横竖屏（宽>高为横屏），
    /// 环卡宽 / 平面卡宽的横屏分支都读它；0 = 调用方没传，环卡回落
    /// 旧公式、平面卡回落 tier 分档。
    @Published var screenHeight: CGFloat = 0
    /// r46-1：第 1 件——环几何的真屏宽/高基准（UIScreen.main.bounds.size，
    /// 不走调用方同步的 geo：首页/播放器的 geo 在用户机上被系统垫到
    /// 约 750pt（r44 注：实测屏宽约 753pt；PlayerView.swift 文件底 r22a：
    /// geo 安全区被垫高到 124），按 geo 算横屏环卡只有约 185pt；用户实拍
    /// 中心卡 153pt——185 的卡在展开中途帧（entryT≈0.33）正是 153pt，
    /// 而 215 的卡再怎么展开也不会小于 159pt（215×0.74），所以实测
    /// 153pt 本身就证明了环卡不是 215、是 geo 下的 185pt，展开动画
    /// 与弹簧没有坏（竖屏实拍 160pt = 0.398×402 恰好，也证明展开能跑完）。
    /// 真屏 874 → 环卡 0.246×874 = 215pt（用户 21:37 确认的改大稿），
    /// 竖屏真屏 = geo = 402 → 160pt 不动。只用于环几何（ringCard /
    /// ringRadius / ringStep 守卫 / hitTestRingCard 的 panelRect 回落）；
    /// 平面卡 flatCard 不动、仍走 geo 的 screenWidth/screenHeight。
    /// 模型是 @MainActor，UIScreen.main.bounds 在主线程读，安全。
    var ringBasisWidth: CGFloat { UIScreen.main.bounds.size.width }
    var ringBasisHeight: CGFloat { UIScreen.main.bounds.size.height }
    /// 面板是否为深场（调用方按专辑取色 field 同步，见 HomeView AlbumTone）：
    /// 深场时平面卡歌名/歌手/提示用白字，浅场用墨字。默认 true
    /// （默认 tone #5b5bd6/#b04f8c/#2f6f8f 是深场，见 AlbumTone.default）。
    @Published var panelIsDark = true
    /// r37-1：平面带卡片只放封面（调用方 HomeView 每日推荐那路传 true，
    /// 见 `HomeCoverRingView.coverOnly`；榜单详情 / 歌单详情那路默认 false，
    /// 卡片仍带歌名/歌手）。
    /// r39-4：第 4 件起 coverOnly 不再藏卡下两行字——平面带卡片在两种
    /// 模式下卡下都画歌名 + 演唱者（`FlatRingCard`，歌名 16pt 粗体、
    /// 演唱者 14pt，居中对齐卡片），带高也不再按 coverOnly 分支
    /// （见 `flatHeight`，恒为卡宽 + 两行字高 + 上抬顶空）。
    /// coverOnly 现在只剩一个作用：封面还没显示出来时的歌名占位
    /// （盖在封面框里的那两行，见 `FlatRingCard` 的 r37-1 追加）只在
    /// coverOnly 时出现；3D 环展开态的环卡（`RingCardView`）标题不动；
    /// 环几何只读 flatCard，不读 flatHeight（`ringCardCenterYLocal`），
    /// 锚点不受影响（只跟 r43-3 的 1pt 顶空走，见该函数）。
    @Published var coverOnly = false
    /// r39-4：点中的平面带卡片下标（`playTrack` 里写，内容换了清掉，
    /// 见 `syncInputs`）。`FlatRingCard` 认它上抬 1pt（`isSelected`；r43-3）。
    /// nil = 没点中任何卡。
    @Published var selectedFlatIndex: Int?
    /// r39-5：第 5 件——点中的环卡下标（`tapRingCard` 里写，环重开/内容换了
    /// 清掉）。环层认它上抬 1pt（`ringLayerInStrip` 的 offset，与平带卡
    /// `selectedFlatIndex` 同款）；点环卡播歌后环收回，上抬在 430ms 收回
    /// 淡出里可见。nil = 没点中任何环卡。
    @Published var selectedRingIndex: Int?
    /// r36：点卡播歌时一并带上的队列标题（`PlaybackStore.setQueue(_:startAt:title:)`，
    /// 队列非空时不传标题会把 queueTitle 置 nil——搜索带若不传，
    /// 搜索 queueTitle + 置顶行会丢）。每日推荐那路传 nil（环本来不带标题）。
    /// 非 Published：只在 playTrack 里读，不驱动渲染。
    var queueTitle: String?

    // MARK: 平面跑马带

    @Published var flatOffsetX: CGFloat = 0
    @Published var flatSetWidth: CGFloat = 0
    @Published var flatDragging = false
    @Published var flatDwellUntil = Date().addingTimeInterval(2.5)
    /// 平面带按压开始的时间（非 Published：只给 tickFlat 的看门狗读）。
    var flatDraggingSince: Date?
    /// r34：平带诊断（非 Published：只给看门狗读，不驱动渲染）。
    /// - flatDwellReason：flatDwellUntil 最后一次是被谁重停的
    ///   （"init" / "ids-changed" / "touch-ended" / "close-done" /
    ///   "watchdog"）；下次再报“带子不动”，日志直接报是哪一项拦的。
    /// - flatLastStripActivity：带子上最后一次触摸活动（began / moved）；
    ///   看门狗只在 3s 无活动时才清卡住的旗——活拖动不会被误清。
    /// - flatLastLinkFire：display link 最后一次回调的时间；看门狗用它
    ///   判 link 死活（1s 无回调 = link 死了，就地重建）。
    /// - flatLastLinkRecreate：上次重建 link 的时间（重建节流，1s 内不连建）。
    /// - flatLinkDeaths：本模型生命周期里重建过几次 link（诊断字段）。
    var flatDwellReason = "init"
    var flatLastStripActivity = Date()
    var flatLastLinkFire = Date()
    var flatLastLinkRecreate = Date.distantPast
    var flatLinkDeaths = 0
    /// 平面跑马带驱动（r31：r26 的 30Hz Timer → CADisplayLink，见文件头）：
    /// 一次创建、`.common` 模式；display link 经 RunLoop 强持，模型走了
    /// 它不会跟着走——回调走弱引用代理（`FlatDisplayLinkProxy`），不让
    /// link 强持模型造成循环引用；HomeView 每次切页回来都重建
    /// （RootView `.home` 分支新建 HomeView → 新 HomeCoverRingModel），
    /// 模型释放时 deinit 停表，不停每回首页漏一个空转驱动。
    /// 上一帧时间戳（回调算 dt 用；0 = 还没走过第一帧）。
    private var flatDisplayLink: CADisplayLink?
    private var flatLinkProxy: FlatDisplayLinkProxy?
    /// r31-settings-sections：120Hz 开关拨动通知的订阅 token（startFlatTimer
    /// 里注册，deinit 里注销；通知回调当场重算已建 link 的帧率上限）。
    private var frameRateObserver: NSObjectProtocol?
    private var flatLastTimestamp: CFTimeInterval = 0
    /// r33-marquee 看门狗 Timer（与 rail 驱动同款，见 HomeView.swift）：
    /// display link 之外的第二条命；0.1s 看一次。
    /// r34：它是独立驱动，不是 link 的附庸——顺序是先查 link 存活
    /// （1s 无回调就重建）、再清卡住的拖动旗（3s 无触摸活动）、
    /// 最后才是守卫 + 该走不动时自己推一步。r33 的顺序反了：清旗写在
    /// `guard !flatDragging` 之后，旗子卡住时守卫先 return，清旗那行
    /// 永远到不了（见 flatWatchdogTick）。
    private var flatWatchdog: Timer?
    private var flatLastOffsetX: CGFloat = 0
    private var flatLastOffsetChange = Date()
    private var flatWatchdogLoggedStuck = false

    /// 模型走时停掉自己的 display link（r26 补 Timer 版，r31 同款）：
    /// 不停，RunLoop 会一直强持它空转；停了，下次回首页新模型重新
    /// startFlatTimer，不影响跑马带恢复。
    /// r31-settings-sections：注销 120Hz 开关通知订阅（不注销，
    /// NotificationCenter 的闭包一直活着，虽然只弱持模型不会漏模型，
    /// 但每次回首页都会多攒一个空转订阅）。
    deinit {
        flatDisplayLink?.invalidate()
        flatWatchdog?.invalidate()
        ringSpringLink?.invalidate()
        if let frameRateObserver { NotificationCenter.default.removeObserver(frameRateObserver) }
    }
    /// 平面带上的按压判定（非 Published：只在手势闭包里读写，不驱动渲染）。
    var stripPress: StripPress?

    // MARK: 环

    @Published var ringPhase: RingPhase = .closed
    /// 环转角（度）：0 = 锚点卡居中；向左拖为负，中心槽位随之向前。
    @Published var angle: CGFloat = 0
    /// 展开进度 0→1（ENTER_MS=520，easeOutQuint 近似）。
    @Published var entryT: CGFloat = 0
    /// 收回进度 0→1（CLOSE_MS=430 / 快收 220，easeInCubic 近似）。
    @Published var closeT: CGFloat = 0
    /// 覆盖层不透明度（展开 260ms 淡入，收回跟 closeT 走）。
    @Published var overlayOpacity: CGFloat = 0
    /// 平面带中心（"liziHome" 坐标空间 = 覆盖层本地坐标，用于环的纵向锚点）。
    @Published var stripCenter: CGPoint = .zero
    @Published var stripSize: CGSize = .zero

    /// 展开时的锚点卡下标（手指下最近的那张，壳版 nearestFlatIdx）。
    var anchorIndex = 0
    var ringDragging = false
    // r51（D5）：isRingDragging 已删——全仓无读取方（只剩四处写入：openRing/closeRing/ringDragStart/ringDragEnded，
    // 随之一并删）；它原来驱动的「拖动时顶部再暗一档」那层 r36-8 已删，壳版 ring.js 里也没有拖动加暗。
    /// 开环时手指的纵坐标（平面带本地坐标），环里下滑退出用（>90px）。
    var ringOpenY: CGFloat = 0
    var ringStartAngle: CGFloat = 0
    var ringStartX: CGFloat = 0
    /// 本次环拖动的起点纵坐标（下滑退出用，ring.js onPressMove ring 分支
    /// `dy > 90` 的起点；平面带入口取开环点 `ringOpenY`，覆盖层入口取
    /// 触摸落点——两者与各自的 x 在同一坐标系里）。
    var ringDragStartY: CGFloat = 0
    /// 最近 110ms 的（时间，转角）采样，用于松手角速度。
    var ringSamples: [(time: Date, angle: CGFloat)] = []
    /// 松手弹簧的驱动状态（r36-8，壳版 advanceRing 的原生版）：
    /// - ringSpringTarget：弹簧目标槽位角，nil = 没在跑；
    /// - ringSpringVelocity：当前角速度（度/秒），松手那一刻的 v 直接带进来
    ///   （壳版 advanceRing 就是从这个 v 起步积分；SwiftUI spring 吃不到
    ///   初速度，松手先死停再爬过去，是「一顿」的来源之一，见 ringDragEnded）；
    /// - link/proxy/lastTimestamp：CADisplayLink 驱动（与平面带的
    ///   FlatDisplayLinkProxy 同款弱引用代理，不让 link 强持模型）。
    var ringSpringTarget: CGFloat?
    var ringSpringVelocity: CGFloat = 0
    private var ringSpringLink: CADisplayLink?
    private var ringSpringProxy: RingSpringDisplayLinkProxy?
    private var ringSpringLastTimestamp: CFTimeInterval = 0
    /// 带子上沿到环顶的距离（r36-8，第 2 条）：壳版视频里顶栏底到环顶
    /// 约 133pt，原生约 110pt，差 23pt——环在面板里偏高、贴着顶栏。
    /// 本文件内给带子容器加这段顶距（平带与环一起下移，r34 的绑定不动；
    /// 壳版闭合态带子也在面板下半部，闭合态一起对上）。面板封顶账里有
    /// 约 36–43pt 余量（flatCard+217，见 HomeView），24pt 不顶出提示行。
    static let stripTopInset: CGFloat = 24
    /// 收回任务代号：新开环 / 新拖动即 +1，旧任务醒来发现代号变了就作废。
    var closeGeneration = 0
    /// 展开动画代号（r33，第 5 条）：openRing +1，closeRing +1；deferred 的
    /// 展开动画醒来时代号变了说明环已经关了，不跑动画。不能复用
    /// closeGeneration——ringDragEnded / ringTouchBegan 也会 +1（取消松手
    /// 收回），会把还没跑的展开动画误杀（手指开环后 16ms 内抬起就中招，
    /// 环会一直 entryT=0 不可见、直到 1s 后收回）。
    var entryGeneration = 0
    /// 上次预取封面时的中心槽位（r33，第 2 条）：中心槽位没变不重复预取。
    var lastPrefetchCenterSlot: Int?

    var isRingOpen: Bool { ringPhase == .open }

    /// 环当前中心槽位（相对锚点的整数格，r33 联动用）：angle 除以槽距取整。
    var ringCenterSlot: Int {
        Int((-angle / ringStep).rounded())
    }

    // r51：`ringCenterTrackIndex` 已删——`syncFlatOffsetToRingCenter` 已拆，本属性无调用方（r33 联动用）。

    // MARK: 常量（壳版 ring.js 原值，见文件头）

    static let dragThreshold: CGFloat = 10       // 平面带上超 10px 才判方向
    static let ringThreshold: CGFloat = 5        // 环里超 5px 才算拖动
    static let holdMs: Double = 1000            // 松手后环保持多久再收
    static let enterMs: Double = 520             // 环展开
    static let closeMs: Double = 430             // 自动收回
    static let quickCloseMs: Double = 220        // 点空白快收
    static let tau: CGFloat = 1.08               // 惯性时间常数
    static let springStiffness: CGFloat = 118    // 弹簧
    /// 临界阻尼 2√118 ≈ 21.73（壳版 advanceRing 原式；r36-8 前的
    /// SwiftUI `.spring(response: 0.58, dampingFraction: 1.0)` 只对上了
    /// 频率（2π/√118 ≈ 0.58s），吃不到初速度、也不是 1/240s 积分——见
    /// ringDragEnded / startRingSpring）。
    static var springDamping: CGFloat { 2 * sqrt(springStiffness) }
    /// 弹簧积分步长 1/240s（壳版 advanceRing 原式：每帧 dt 内按 1/240s
    /// 子步半隐式欧拉，只把每帧末的角发出去渲染）。
    static let springStep: Double = 1.0 / 240
    static let maxVelocity: CGFloat = 1400       // 角速度限幅（度/秒）
    static let sampleMs: Double = 0.110          // 角速度采样窗
    static let dragGain: CGFloat = 1.45          // 拖动增益
    static let resumeMs: Double = 1200           // 平面带松手后多久恢复自动走
    static let initialDwell: Double = 2.5        // 初画/回卷后停多久再走
    static let dragResumeDwell: Double = 1.2     // 平面带拖动松手后停多久再走
    // r28：与上面 resumeMs=1200 对上（39.6s 视频规格：松手 1200ms 后恢复；
    // 之前 dragResumeDwell=1.0，resumeMs 白定义了没人用）。
    static let closeResumeMs: Double = 220       // r51：第 1 件——收环 dwell 改回套壳 220ms（壳版 ring.js finishClose:653 `flat.resumeAt = now() + 220`；r46-6 的 2000ms 作废）。松手恢复仍是 resumeMs=1200，对照壳版 ring.js:57 RESUME_MS=1200，一字不动。
    static let swipeDownExit: CGFloat = 90       // 环里下滑超 90px 退出

    // MARK: 内容（r26-3D：永远是当前平台的每日推荐；队列优先已删）

    /// r26-3D：环/跑马带的内容 = 当前平台的每日推荐（壳版 `ringItems()` =
    /// 当前来源 S.items，`applyResult` 每次切平台/切来源都 `setItems`）。
    /// r20 的「队列优先、每日兜底」已删：它让切平台后首屏看不到变化
    /// （播过歌后每日在面板里让位给队列，22:29 截图的结构问题；面板标题
    /// 就是「每日推荐」，带子却不是每日内容）。切平台 → daily 变 →
    /// syncInputs 换内容；播歌不改变带子内容（Hero 才是当前播放那首，
    /// 壳版 `applyResult` 注释原话）；点卡播歌整份每日进队列（见 playTrack）。
    var tracks: [Track] { dailyTracks }

    /// r43-2：第 2 件——通用路开关：genericCards 非 nil 时环走通用卡。
    var isGeneric: Bool { genericCards != nil }
    /// r43-2：环的条目数（通用路 = 卡数，曲目路 = 曲数，与旧 tracks.count 同值）。
    var itemCount: Int { genericCards?.count ?? tracks.count }
    /// r43-2：条目 id 集（内容换了才重置的判定用；曲目路 = 曲 id 集，与旧 tracks.map(\.id) 同值）。
    var itemIDs: [String] { genericCards?.map(\.id) ?? tracks.map(\.id) }
    /// r43-2：第 i 张卡的渲染内容（通用路 = 该卡本身；曲目路 = 该曲合成的卡，
    /// id = platform:id、subtitle = 歌手、onTap 不填、VoiceOver「播放：标题」）。
    func itemCard(at index: Int) -> HomeRingCard {
        if let cards = genericCards, cards.indices.contains(index) { return cards[index] }
        let t = tracks[index]
        return HomeRingCard(id: t.platform + ":" + t.id, coverURL: t.coverURL,
                            title: t.title, subtitle: t.artist,
                            accessibilityLabel: "播放：\(t.title)")
    }

    /// 在播曲目在当前列表里的下标（开环锚点 + 点中态跟随用；不在列表里回 nil，
    /// 开环回落手指卡/正中卡）。
    /// r45-3：通用路也有曲目卡（榜单详情 / 打开的集合 / 各栏里的曲目行），
    /// 它们的卡 id 与曲目路同式（"platform:id"，见 HomeView marqueeCards /
    /// openedTrackCards 的 r45-3 改动），直接按 id 找，不再分路；集合卡
    /// （歌单/专辑/电台/榜单）的 id 带类型前缀，不会撞上曲目键。
    /// r43-2 的旧注（通用路没有在播概念）随之作废：混合列表里的集合卡
    /// 本来就没有在播曲目可对，找不着自然回 nil，不用再拿 isGeneric 挡。
    var playingIndex: Int? {
        guard let key = playingKey else { return nil }
        if let cards = genericCards {
            return cards.firstIndex { $0.id == key }
        }
        return tracks.firstIndex { $0.platform + ":" + $0.id == key }
    }

    /// 调用方数据同步进来；曲目 id 集合变了（切平台/重拉）才重置
    /// （壳版 setItems 同款语义）。
    func syncInputs(daily: [Track], isLoading: Bool,
                    spinnerVisible: Bool,
                    emptyReason: String?, playing: Track?,
                    speed: CGFloat,
                    tier: PlayerTokens.PlayerSizeTier,
                    screenWidth: CGFloat = 0, // r39-5：第 5 件——实测屏宽，见 screenWidth
                    screenHeight: CGFloat = 0, // r43-1：第 1 件——实测屏高，判横竖屏用，见 screenHeight
                    panelIsDark: Bool = true,
                    queueTitle: String? = nil,
                    coverOnly: Bool = false,
                    cards: [HomeRingCard]? = nil) { // r43-2：第 2 件——通用卡（rail 四栏 + 榜单目录）；nil = 曲目路
        startFlatTimer()
        let oldIDs = itemIDs // r43-2：第 2 件——通用路比卡 id 集，曲目路比曲 id 集（与旧 tracks.map(\.id) 同值）
        dailyTracks = daily
        genericCards = cards // r43-2：第 2 件
        self.queueTitle = queueTitle
        playingKey = playing.map { $0.platform + ":" + $0.id }
        isLoadingDaily = isLoading
        dailySpinnerVisible = spinnerVisible
        dailyEmptyReason = emptyReason
        marqueeSpeed = speed
        self.tier = tier
        self.screenWidth = screenWidth // r39-5：第 5 件
        self.screenHeight = screenHeight // r43-1：第 1 件
        self.panelIsDark = panelIsDark
        self.coverOnly = coverOnly
        if itemIDs != oldIDs { // r43-2：第 2 件——通用路比卡 id 集，曲目路比曲 id 集（与旧 tracks.map(\.id) 同值）
            if ringPhase != .closed { closeRing() }
            flatOffsetX = 0
            flatDwellUntil = Date().addingTimeInterval(Self.initialDwell)
            flatDwellReason = "ids-changed"
            selectedFlatIndex = nil // r39-4：内容换了（切平台/重拉），点中态清掉，不指到另一首上
            selectedRingIndex = nil // r39-5：第 5 件——环卡点中态同清
        }
        // r45-3：点中态跟随当前播（切歌 / 自动播下一首后，上抬的卡必须是
        // 正在播的那首，不能赖在上一首上——"滑动后卡片不同步"的一半根因：
        // 旧代码只在点卡时写 selectedFlatIndex，切歌后从不动它，自动播
        // 下一首后上抬还指着上一首）。在播曲目不在当前列表里时回 nil，
        // 清掉上抬，不指错歌。放在内容换列表的清零之后：换了内容也按
        // 新列表重算，不残留。点卡那一下也对得上：点中的卡成了当前播，
        // playingIndex 就是点中的下标，同值，不闪。
        selectedFlatIndex = playingIndex
        // r33-marquee：带宽兜底（与 rail 的 ensureSetWidth 同款）：
        // flatSetWidth 正常由 FlatSetWidthKey 偏好上报；偏好没到时 tickFlat
        // 的 setWidth > 0 守卫永远拦住、带子永远停。只在 flatSetWidth 小于
        // 一份宽度且有曲目时按卡数补，与偏好公式同值（n×(卡宽+间距)）。
        // r34：`== 0` 改成 `< 一份宽度`——偏好在布局完成前会先报 0，
        // 偏好处理把它写成 0+16=16，旧的 `== 0` 再也修不回来（16 ≠ 0），
        // 带子只能在 16pt 里打转、看着就是冻住。小于一份宽度只可能是
        // 布局前的 0/残值，直接按卡数补满。
        if flatSetWidth < CGFloat(itemCount) * (flatCard + flatGap), itemCount > 0 { // r43-2：第 2 件——卡数，曲目路与旧 tracks.count 同值
            flatSetWidth = CGFloat(itemCount) * (flatCard + flatGap)
        }
        // r51：第 1 件——r48-3 跟随块已拆（改回套壳语义）：切歌/自动播下一首
        // 不再写 flatOffsetX、不再留 2s dwell；syncInputs 只推状态，带子停在
        // 旧位置接着滚。上方 `selectedFlatIndex = playingIndex`（r45-3）保留：
        // 只标记在播卡上抬/高亮，不动位置。内容换了仍走上面的 ids-changed
        // 分支 flatOffsetX=0 从头显示（壳版 setItems → resetFlat 同款）。
    }

    // MARK: 尺寸（视频实测，见文件头分档表）

    /// 平面卡宽：compact 180 / standard 190 / large 209（≈0.486vw，
    /// 39.6s 新视频卡 350px/720px）。r43-1：第 1 件——横屏时改 0.181×vw
    /// （用户横屏平面带实拍卡宽 18.1% 屏宽，874pt → 158pt，正方形一排 5 张），
    /// 竖屏仍走 tier 分档。横竖屏由 screenHeight 判（>0 且宽>高为横屏），
    /// 没传屏高时回落 tier 分档。
    var flatCard: CGFloat {
        if screenHeight > 0, screenWidth > screenHeight {
            return screenWidth * 0.181
        }
        switch tier {
        case .compact: return 180
        case .standard: return 190
        case .large: return 209
        }
    }

    var flatGap: CGFloat { 16 }

    var flatPitch: CGFloat { flatCard + flatGap }

    /// r39-4：卡下两行字高 52（歌名 16 + 间距 7 + 歌手 14 + 行高余量，
    /// 与旧非 coverOnly 的 +52 同值；见 `flatHeight`）。
    static let titleArtistHeight: CGFloat = 52
    /// r43-3：第 3 件——点中卡片的上抬量 1pt（整体上抬，封面 + 两行字一起；
    /// 带高里预留这 1pt 作顶空，平时卡片顶距带顶 1pt，点中那张回到带顶，
    /// 其余卡片不动——都在同一平行线上，只有点中的高一点点）。
    static let selectedLift: CGFloat = 1 // r43-3：第 3 件——点中上抬 6pt → 1pt

    /// 平面带高：顶空 1（r43-3 点中上抬预留，原 6pt）+ 卡 + 间距 7 + 16pt 歌名行
    /// + 间距 7 + 14pt 歌手行（= 卡宽 + 53）。
    /// r39-4：第 4 件——coverOnly 不再减带高：每日推荐 / 榜单详情 /
    /// 正在播放那几路（coverOnly: true）卡下也画歌名 + 演唱者两行，
    /// 与歌单详情那路（false）同高；r37-1 的「coverOnly 时带高 = 卡宽」
    /// 作废。卡宽/卡高/间距不动；面板封顶公式（flatCard + 217）不动，
    /// 本来就含这两行字的 52pt 空位（见 HomeView.swift 面板封顶账）。
    /// 卡高推导只在这里（与 `ringCardHeight` 同款单一位置）。
    var flatHeight: CGFloat { flatCard + Self.titleArtistHeight + Self.selectedLift }

    /// r44（第 3 件）：竖屏 0.393→0.398×vw（排行榜竖屏实测 160pt/39.8% 屏宽，
    /// 全模式统一用排行榜那个大小）；横屏 0.246×vw 不动——实测屏宽约 753pt
    /// （outer.size.width，安全区已扣），代码实际约 185pt，不是 r43 注释里
    /// 按 vw=874 算的纸面 215pt，也不是用户实拍中途帧的 159pt（见交回）；
    /// 横屏 0.246×vw 配合新 pitch/R 验算铺得开（见 ringPitch）。
    /// r46-1：第 1 件——调用方现在传真屏宽（ringBasisWidth）进来：横屏
    /// 0.246×874 = 215pt 是渲染实值（用户 21:37 确认的改大稿），
    /// 竖屏 0.398×402 = 160pt 不动；旧「geo 下 185pt」的说法随之作废。
    static func ringCardWidth(screenWidth: CGFloat, screenHeight: CGFloat = 0) -> CGFloat {
        if screenHeight > 0 {
            return screenWidth > screenHeight ? screenWidth * 0.246 : screenWidth * 0.398
        }
        return min(max(screenWidth * 0.24, 84), 112)
    }

    /// 环卡宽（r39-5：第 5 件——有实测屏宽时按 ringCardWidth 现算；没传屏宽时
    /// 回落旧 tier 分档；r43-1：横竖屏按 screenHeight 取 0.246/0.393×vw；
    /// r46-1：第 1 件——屏宽取真屏基准 ringBasisWidth（横屏 215pt、竖屏 160pt），
    /// 不再取 geo 的 screenWidth（横屏只有约 750pt，卡只有约 185pt）。
    var ringCard: CGFloat {
        if ringBasisWidth > 0 { return Self.ringCardWidth(screenWidth: ringBasisWidth, screenHeight: ringBasisHeight) }
        if screenWidth > 0 { return Self.ringCardWidth(screenWidth: screenWidth, screenHeight: screenHeight) }
        switch tier {
        case .compact: return 141
        case .standard: return 149
        case .large: return 164
        }
    }

    /// 环槽位数 n = min(曲数, cap)（r39-5：第 5 件——壳版 openRing 原式；旧 ringCap
    /// 已是公式值，n 之前没单独成量，ringStep 写死 40° 时用不上）。
    var ringSlotCount: Int {
        min(itemCount, Int(ringCap)) // r43-2：第 2 件——条目数，曲目路与旧 tracks.count 同值
    }

    /// 相邻槽位夹角（r39-5：第 5 件——壳版公式 step = min(360/n, 2·asin(pitch/(2R)))，
    /// 角度制；r35 的写死 40° 是旧 ringCard（141/149/164）+ 旧 R 下的
    /// 公式值，卡宽/R 换成套壳版后不再成立——竖屏 402pt 约 35.2°、
    /// 横屏 852pt（10 首）约 15.7°。asin 入参夹到 [-1, 1]（壳版同款）。
    /// 没传屏宽时回落 40°（与旧弦长半径配套，见 ringRadius）。
    /// 曲数为 0 时 step 无意义，回 40° 免得除零（visibleSlots 已空）。
    /// r44（第 3 件）：pitch 1.40 + R 除数 0.42 后竖屏 step 仍 51.4°
    /// （360/n 分支，n=7），横屏约 23.3°（asin 分支，10 首）——
    /// D 不再是旧 100pt，见 ringPitch。
    var ringStep: CGFloat {
        guard ringBasisWidth > 0, ringSlotCount > 0 else { return 40 } // r46-1：第 1 件——守卫改走真屏基准（与 ringCard/ringRadius 同源）
        let asinDeg = 2 * asin(min(max(ringPitch / (2 * ringRadius), -1), 1)) * 180 / .pi
        return min(360 / CGFloat(ringSlotCount), asinDeg)
    }

    /// 槽距 = 卡宽×1.40（r44 第 3 件：r43 把卡改大后 R 仍是旧卡宽下的值，
    /// 相邻槽投影间距竖屏仅约 100pt、比 158pt 卡宽小 57pt，必然重叠；
    /// 且只改 pitch 无效——step 被 360/n 分支压住，pitch 只经 cap 间接影响。
    /// 与 ringRadius 除数 0.42 联动：竖屏 D≈178pt、间隙 +18pt、字行间隙 +27pt，
    /// 横屏 D≈249pt、间隙 +63pt，三卡总跨 684pt 占面板内容宽 704pt 约 97%，
    /// 铺得开；r35 的 1.14（壳版原式）作废——壳版卡小，r43 的大卡配不上）。
    var ringPitch: CGFloat { ringCard * 1.40 } // r44：第 3 件——1.14→1.40

    /// 环容量 cap = clamp(round(2πR/pitch), 7, 64)（壳版 openRing 原式；
    /// r39-5：第 5 件——竖屏 402pt round(10.40) = 10，横屏 852pt round(22.99) = 23；
    /// 旧值 9 是旧 ringCard/R 下的数）。n = min(曲数, cap)，见 ringSlotCount。
    var ringCap: CGFloat {
        min(max((2 * .pi * ringRadius / ringPitch).rounded(), 7), 64)
    }

    /// 圆柱半径（r39-5：第 5 件——壳版 openRing 原式 R = max(Rview, cardW×0.8)，
    /// Rview = (vw/2 − edgePad − cardW/2) / 0.42，edgePad = 14；
    /// r44 第 3 件：除数 0.762→0.42，与 ringPitch 1.40 联动——竖屏 R≈255pt、
    /// 横屏 R≈645pt（实测屏宽约 753pt）；旧 0.762 是按 94pt 小卡算的，
    /// 配 r43 的大卡竖屏 R 仅 142pt、相邻槽角被 360/n 压到 51.4°、投影间距
    /// 仅 100pt，卡必然重叠。新 R 下竖屏/横屏均走 asin 分支（step 51.4°/23.3°，
    /// D 对条目数稳定）；拖动跟手速度 ringPerPixel 与 R 无关（恒 1.45pt/px），
    /// 改 R 不影响拖动速度。
    /// r46-1：第 1 件——半径按真屏宽：横屏 R = (874/2−14−215/2)/0.42 ≈ 751pt
    /// （旧 geo 下约 645pt 作废），竖屏 R≈255pt 不动。
    /// 没传屏宽时回落旧弦长公式（r35：pitch 换回卡宽×1.14 后标准档
    /// 169.86/(2·sin20°) ≈ 248pt，compact ≈ 235pt，large ≈ 273pt）。
    var ringRadius: CGFloat {
        if ringBasisWidth > 0 { // r46-1：第 1 件——半径按真屏宽
            let rView = (ringBasisWidth / 2 - 14 - ringCard / 2) / 0.42 // r44：第 3 件——0.762→0.42
            return max(rView, ringCard * 0.8)
        }
        return ringPitch / (2 * sin(ringStep * .pi / 360))
    }

    /// 透视距离 P = max(3.2R, 520)（壳版 ring.js openRing 原式：
    /// `P = Math.max(R * 3.2, 520)`；r39-5：第 5 件——竖屏 402pt 3.2×182 ≈ 583pt、
    /// 横屏 852pt 3.2×467 ≈ 1495pt，都 > 520、都取 3.2R）。
    /// 卡片旋转不再用 SwiftUI perspective 0.5，
    /// 透视全程只走这个显式 P（见 cylinderZ / perspectiveFactor）。
    var ringPerspective: CGFloat {
        max(3.2 * ringRadius, 520)
    }

    /// 每像素转角度数（壳版：180/(πR)×1.45）。
    var ringPerPixel: CGFloat {
        (180 / (.pi * ringRadius)) * Self.dragGain
    }

    /// 环卡总高：封面 + 间距 5 + 15pt 歌名行 + 间距 5 + 13pt 歌手行
    /// （r28：歌名 13→15、歌手 11→13，见 RingCardView）。
    /// r39-5：第 5 件——壳版 cardH = cardW + 28 是一行歌名（11px + 间距 5 + 余量）；
    /// 原生环卡是两行（歌名 + 歌手，视频规格、每张环卡下都有），故 +46
    /// 不动——只取壳版的封面宽 cardW，不取它的一行卡高；23pt 文字段
    /// （(ringCardHeight − ringCard)/2，见 ringCardCenterYLocal）随之不变。
    /// 卡高推导只在这里（与 flatHeight 同款单一位置）。
    var ringCardHeight: CGFloat { ringCard + 46 }

    // MARK: 平面跑马带

    /// 驱动只建一次（幂等；syncInputs 首行即调，首个 sync 就是 onAppear）。
    /// r31：r26 的模型自持 30Hz Timer → CADisplayLink（见文件头）——
    /// View 结构体的 `Timer.publish(...).autoconnect()` 不能用（r25 断点 1：
    /// 每次 body 重算都重建 publisher 并重新订阅，33ms 倒计时反复重启，
    /// 计时器可能永远等不到触发）；30Hz Timer 同样不能用（用户 2026-11-21
    /// 「一卡一卡」：0.8px/步的离散跳变 + Task 跳主线程的调度抖动）。
    /// display link 跟屏幕刷新同步、`.common` 模式（页面滚动时也走，
    /// 与旧 Timer 的 `.common` 同款）；回调经弱引用代理直接在主线程跑
    /// （`FlatDisplayLinkProxy`：display link 强持 target，不代理就漏；
    /// r31-marquee 起不再经 Task 跳主线程，见代理处注释），
    /// 步长在 tickFlat 里按真实帧间隔 dt 算。
    func startFlatTimer() {
        guard flatDisplayLink == nil else { return }
        let proxy = FlatDisplayLinkProxy(model: self)
        let link = CADisplayLink(target: proxy, selector: #selector(FlatDisplayLinkProxy.fired(_:)))
        // r31-settings-sections：帧率上限跟设置页「120Hz 高刷新率」开关走
        //（SettingsStore.frameRateRange()：开 = 30–120/首选 120，
        // 关 = 30–60/首选 60；默认开，与 120Hz 工硬编码 120 的既有行为
        // 一致）。plist 解锁是编译期、运行时关不掉，开关能控的就是这行。
        link.preferredFrameRateRange = SettingsStore.frameRateRange()
        link.add(to: .main, forMode: .common)
        flatLinkProxy = proxy
        flatDisplayLink = link
        // r33-marquee：看门狗 Timer 与 link 同生（幂等，见 startFlatWatchdog）。
        startFlatWatchdog()
        // 开关拨动时已建好的 link 当场重算上限：设置页拨完回首页，
        // 模型不一定重建（RootView 可能复用），只靠 start 时读一次会漏；
        // 订阅只注册一次（本函数幂等，guard 拦住重复进），deinit 注销。
        // 闭包只弱持模型，不循环引用；queue .main，所以回调必在主线程，
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
        flatDisplayLink?.preferredFrameRateRange = SettingsStore.frameRateRange()
    }

    /// r34：display link 重建（看门狗调）：旧 link 失效 + 置 nil 后
    /// 走 startFlatTimer 重建（幂等 guard 靠 flatDisplayLink == nil）。
    /// 1s 内不连建（flatLastLinkRecreate 节流）；通知订阅在
    /// startFlatTimer 里重复注册会多攒一个——重建前先注销旧的
    /// （startFlatTimer 里 frameRateObserver 被重新赋值，旧订阅
    /// 必须先注销，否则每次重建多一个空转订阅）。
    private func restartFlatLink() {
        guard Date().timeIntervalSince(flatLastLinkRecreate) >= 1 else { return }
        flatLastLinkRecreate = Date()
        flatLinkDeaths += 1
        flatDisplayLink?.invalidate()
        flatDisplayLink = nil
        flatLinkProxy = nil
        flatLastTimestamp = 0
        if let frameRateObserver { NotificationCenter.default.removeObserver(frameRateObserver) }
        frameRateObserver = nil
        startFlatTimer()
        DiagLog.shared.recordLog(category: "marquee", message: "flat display link rebuilt", fields: ["deaths": flatLinkDeaths])
    }

    /// display link 回调（主线程）：按真实帧间隔 dt 推进跑马带。
    /// dt 从 link.timestamp 差算（不是回调到达时间，所以 Task 跳主线程
    /// 的几毫秒延迟不扭曲步长）；第一帧没有上一帧，用 1/60s 起步。
    /// r31 前是 30Hz Timer：每步 0.8px 离散跳变，肉眼一顿一顿。
    /// r34：记最后一次回调时间（看门狗用它判 link 死活）。
    fileprivate func flatDisplayLinkFired(_ link: CADisplayLink) {
        flatLastLinkFire = Date()
        let dt: CFTimeInterval
        if flatLastTimestamp == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = link.timestamp - flatLastTimestamp
        }
        flatLastTimestamp = link.timestamp
        tickFlat(dt: dt)
    }

    func tickFlat(dt: CFTimeInterval = 1.0 / 60.0) {
        // r26 看门狗：flatDragging 只由 stripTouchBegan 置起、只由
        // stripTouchEnded 清掉；一旦某次触摸的 ended 没走到模型（识别器
        // .failed、触摸被系统取消、触摸层中途被拆掉），旗子就永远卡住、
        // 跑马带永远停——22:29 截图就是这副样子（走了约 1s 的量后冻住）。
        // 手指按住不动 10s 不是真实拖动，超时直接清掉、让带子恢复；
        // 环开着时本函数仍被 ringPhase 挡住，不会误走。
        if flatDragging, let since = flatDraggingSince,
           Date().timeIntervalSince(since) > 10 {
            flatDragging = false
            flatDraggingSince = nil
            stripPress = nil
        }
        guard itemCount > 0, flatSetWidth > 0, !flatDragging,
              ringPhase == .closed, Date() >= flatDwellUntil else { return }
        // r31：步长 = 速度 × 真实帧间隔。dt 夹取：后台回来 / 卡顿后第
        // 一帧 timestamp 差可能很大，不夹会一次跳几十 px（跳变）；
        // 夹到 0.1s 后一步最多 2.4px，肉眼仍是连续的；dt <= 0
        // （时钟异常）时不动，不倒走。60Hz 约 0.4px/步、120Hz 约 0.2px/步。
        let clamped = min(max(dt, 0), 0.1)
        guard clamped > 0 else { return }
        flatOffsetX = normalizedFlat(flatOffsetX - marqueeSpeed * CGFloat(clamped))
    }

    /// r33-marquee：看门狗 Timer 启动（幂等；与 startFlatTimer 同生同死，
    /// deinit 一起停）。Timer 挂 RunLoop.main 的 .common 模式，页面滚动时也跳。
    private func startFlatWatchdog() {
        guard flatWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flatWatchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flatWatchdog = timer
    }

    /// flat 带看门狗每 0.1s 一跳（r34 重写：独立驱动，不再是 link 的附庸）。
    /// 顺序是死的，换顺序就回到 r33 的 bug：
    /// 1. link 存活：1s 无回调 = link 死了，就地重建（restartFlatLink，
    ///    1s 节流）。link 为什么死不用在这里猜——重建 + 记诊断，
    ///    下次日志看 flatLinkDeaths 与回调间隔。
    /// 2. 卡住的旗：flatDragging 真且 3s 无带上触摸活动（flatLastStripActivity）
    ///    → 直接清旗 + 清 press。清旗在守卫之前——r33 把清旗写在
    ///    `guard !flatDragging` 之后，旗子卡住时守卫先 return，清旗那行
    ///    永远到不了；活拖动每步都刷新 flatLastStripActivity，不会被误清。
    /// 3. 守卫（与 tickFlat 一致）：不该走时只刷新基线，不误判、不驱动。
    /// 4. 该走但偏移 3s 没变 → 记诊断（五项守卫的实测值 + dwell 重停原因
    ///    全写进日志，下次再报“不动”直接报是哪一项拦的）+ dwell 归零 +
    ///    自己按速度推一步（2.4px/步 = 24px/s，与 link 活着时同速；
    ///    link 活着时偏移每帧都在变，到不了这一步，绝不与 link 打架）。
    private func flatWatchdogTick() {
        // 1. link 存活（r34）：Timer 自己在跳，link 却 1s 没回调 = link 死了。
        if Date().timeIntervalSince(flatLastLinkFire) >= 1 {
            restartFlatLink()
            flatLastLinkFire = Date()
        }
        // 2. 卡住的旗（r34）：3s 无带上触摸活动，旗子不可能是活拖动。
        if flatDragging, Date().timeIntervalSince(flatLastStripActivity) >= 3 {
            flatDragging = false
            flatDraggingSince = nil
            stripPress = nil
            DiagLog.shared.recordLog(category: "marquee", message: "flat drag flag stuck 3s, watchdog cleared", fields: [:])
        }
        // 3. 守卫（与 tickFlat 一致）：不该走时只刷新基线。
        guard itemCount > 0, flatSetWidth > 0, !flatDragging,
              ringPhase == .closed, Date() >= flatDwellUntil else {
            flatLastOffsetX = flatOffsetX
            flatLastOffsetChange = Date()
            flatWatchdogLoggedStuck = false
            return
        }
        if flatOffsetX != flatLastOffsetX {
            flatLastOffsetX = flatOffsetX
            flatLastOffsetChange = Date()
            flatWatchdogLoggedStuck = false
            return
        }
        // 4. 该走但偏移 3s 没变：记诊断 + 自己推一步。
        guard Date().timeIntervalSince(flatLastOffsetChange) >= 3 else { return }
        if !flatWatchdogLoggedStuck {
            flatWatchdogLoggedStuck = true
            DiagLog.shared.recordLog(category: "marquee", message: "flat belt stuck 3s, watchdog driving", fields: ["tracks": itemCount, "setWidth": flatSetWidth, "isDragging": flatDragging, "ringPhase": String(describing: ringPhase), "dwellSeconds": max(0, flatDwellUntil.timeIntervalSinceNow), "dwellReason": flatDwellReason, "offsetX": flatOffsetX, "speed": marqueeSpeed, "linkDeaths": flatLinkDeaths, "linkSilentSeconds": Date().timeIntervalSince(flatLastLinkFire)])
        }
        flatDwellUntil = Date()
        flatDwellReason = "watchdog"
        flatOffsetX = normalizedFlat(flatOffsetX - marqueeSpeed * 0.1)
        flatLastOffsetX = flatOffsetX
    }

    /// 把偏移收进 (-setWidth, 0]，两份循环无缝（DailyMarqueeView 同款）。
    func normalizedFlat(_ x: CGFloat) -> CGFloat {
        guard flatSetWidth > 0 else { return x }
        var v = x
        while v > 0 { v -= flatSetWidth }
        while v <= -flatSetWidth { v += flatSetWidth }
        return v
    }

    /// 手指 x 处最近的平面卡下标（壳版 nearestFlatIdx）。
    func anchorNearestFlatCard(x: CGFloat) -> Int {
        guard itemCount > 0, flatPitch > 0 else { return 0 } // r43-2：第 2 件——条目数，曲目路与旧 tracks 同值
        let pos = (x - flatCard / 2 - flatOffsetX) / flatPitch
        return mod(Int(pos.rounded()), itemCount)
    }

    /// r33，第 4/11 件：带子点按命中校验——点按必须落在某张卡的矩形内才算
    /// 点中那首歌；卡缝（flatGap 16pt）与带上空白处不播歌。之前缺这道校验：
    /// 触摸层盖住整条带，任意点按都按最近卡播歌（点卡缝、点空白也播）。
    /// 环覆盖层同款做法（`hitTestRingCard`：点空处只关环不播歌），带子
    /// 这里补齐。中心算法与 `anchorNearestFlatCard` 同源（未取模的最近
    /// 槽位中心，2n 复制带上的副本位置同样算得准）。
    func isTapOnFlatCard(x: CGFloat) -> Bool {
        guard itemCount > 0, flatPitch > 0 else { return false } // r43-2：第 2 件——条目数，曲目路与旧 tracks 同值
        let pos = (x - flatCard / 2 - flatOffsetX) / flatPitch
        let nearest = Int(pos.rounded())
        let centerX = flatOffsetX + CGFloat(nearest) * flatPitch + flatCard / 2
        return abs(x - centerX) <= flatCard / 2
    }

    // r51（D5）：centerCardIndex() 已删——全仓无调用方（r28 起即暂无调用方，留作备用；本次确认仍无调用方后删除）。

    // MARK: 平面带触摸状态机（壳版 ring.js onPressMove strip 分支，
    // 由 StripTouchView 的 UIPanGestureRecognizer 驱动；x/y 均为平面带本地坐标）

    /// 平面带触摸的移动结果：`.failGesture` = 竖向占优（上滑/下滑都交还），
    /// 识别器自毁、把手势交还 ScrollView（r24「竖向 = 交还页面」同款；
    /// r40：上滑开环已删，改回 r24 横向拖动开环，见 stripTouchMoved）。
    enum StripMoveOutcome {
        case handled
        case failGesture
    }

    /// 手指按下（pan .began）：记按压起点；旧 press 残留（上一根手势被系统
    /// 打断没走到 ended）直接作废重建，否则下次拖动会跳变。
    /// 手指按下就停跑马带（tickFlat 看 flatDragging；ring.js
    /// flat.pressed 同款），松手再按 dragResumeDwell 恢复。
    func stripTouchBegan(x: CGFloat, y: CGFloat) {
        guard ringPhase == .closed else { return }
        flatDragging = true
        flatDraggingSince = Date()
        flatLastStripActivity = Date() // r34：看门狗清旗的活动基线
        stripPress = StripPress(
            startX: x, startY: y, decided: .undecided
        )
    }

    /// 手指移动（pan .changed；r40：删掉上滑开环，改回 r24「横向开环、
    /// 上/下都交还」；r39-5 的壳版 onPressMove strip 分支作废）：
    /// - 环已开（同一根手指）：环拖动还没走出 5px 之前，下滑 >90px 且
    ///   竖向占优 → 收回（ring.js onPressMove ring 分支「明显向下滑 =
    ///   退出环」；5px 死区是 RING_THRESHOLD）；否则继续转环。
    /// - 环没开：10px 内不判方向（ring.js DRAG_THRESHOLD=10）；
    ///   竖向占优（|dy|>|dx|×1.25）：上滑/下滑都 → `.failGesture`
    ///   （识别器自毁，ScrollView 接管滚页面；r24「竖向 = 交还页面」）。
    /// - 其余（非竖向占优）一律横向拖动 → 开环（锚点 = 手指下最近的卡，
    ///   ring.js nearestFlatIdx；手指不抬起继续拖就是转环，
    ///   ring.js enterRing 同款语义）。
    func stripTouchMoved(x: CGFloat, y: CGFloat) -> StripMoveOutcome {
        flatLastStripActivity = Date() // r34：活拖动每步都刷新，看门狗不误清
        if ringPhase == .open {
            if ringDragging, abs(x - ringStartX) < Self.ringThreshold {
                let dx = x - ringStartX
                let dy = y - ringOpenY
                if dy > Self.swipeDownExit, abs(dy) > abs(dx) * 1.25 {
                    closeRing()
                    return .handled
                }
            }
            ringDragMoved(toX: x)
            return .handled
        }
        guard ringPhase == .closed else { return .handled }
        if stripPress == nil {
            stripPress = StripPress(
                startX: x, startY: y, decided: .undecided
            )
            return .handled
        }
        guard var press = stripPress else { return .handled }
        let dx = x - press.startX
        let dy = y - press.startY
        if press.decided == .undecided {
            if hypot(dx, dy) < Self.dragThreshold { return .handled }
            if abs(dy) > abs(dx) * 1.25 {
                // r40：竖向占优——上滑/下滑都交还 ScrollView，上滑开环已删（改回 r24）。
                press.decided = .handedToScroll
                stripPress = press
                return .failGesture
            }
            // r40：其余（非竖向占优）一律横向拖动——开环（锚点 = 手指下最近的卡；
            // 手指不抬起继续拖就是转环，r24 同款；r39-5 的横向手滚跑马带已删）。
            let anchor = anchorNearestFlatCard(x: x)
            openRing(anchor: anchor, atX: x, atY: y)
            press.decided = .openedRing
            stripPress = press
            return .handled
        }
        return .handled
    }

    /// 手指抬起 / 手势取消（pan .ended/.cancelled，ring.js onPressUp /
    /// onPressCancel strip 分支同款：环开着 = 松手走惯性+弹簧吸附；
    /// 环没开 = 跑马带停 dragResumeDwell 再走）。
    func stripTouchEnded() {
        defer { stripPress = nil }
        flatDragging = false
        flatDraggingSince = nil
        if ringPhase == .open {
            ringDragEnded()
            return
        }
        flatDwellUntil = Date()
            .addingTimeInterval(Self.dragResumeDwell)
        flatDwellReason = "touch-ended" // r34：看门狗日志报重停原因
    }

    // MARK: 开环 / 收回

    /// 开环（r40：入口只剩一处——平面带横向拖动 stripTouchMoved，改回 r24；
    /// 入口按钮点按已删；上滑开环已删，竖向拖动交还 ScrollView）。
    /// - `beginDrag: true`（平面带横向拖动）：展开这根手指不用抬起，直接记为
    ///   拖动起点，继续拖就是转环（ring.js enterRing 同款；同一根手指的后续移动
    ///   由平面带的 `StripTouchView` 接着转发，不走覆盖层新挂的手势）。
    /// - `beginDrag: false`：只展开、不接管手指；下一根手指落在覆盖层上时
    ///   由覆盖层手势重新 `ringDragStart`（liziHome 坐标，与本轮的
    ///   `ringStartX` 不混用——一根拖动内的 x 必须同一坐标系）。
    ///   r28：传 false 的唯一调用方（入口按钮）已删，现无调用方传 false，
    ///   参数保留（默认 true），拖动入口 `stripTouchMoved` 不传它。
    /// - 锚点（r26-3D，用户 22:33「当前播的歌在环中间」）：在播曲目在当前
    ///   列表里时锚点就是它（`playingIndex`），手指卡/`anchor` 参数只在
    ///   在播曲目不在列表里时用（回落壳版/视频的手指卡规则）。拖动连续性
    ///   不变：开环角仍从 0 起、ringStartX 仍是手指 x，继续拖就是转环。
    func openRing(anchor: Int, atX x: CGFloat, atY y: CGFloat = 0, beginDrag: Bool = true) {
        guard ringPhase == .closed, itemCount > 0 else { return } // r43-2：第 2 件——条目数，曲目路与旧 tracks 同值
        anchorIndex = playingIndex ?? ((0..<itemCount).contains(anchor) ? anchor : 0)
        angle = 0
        entryT = 0
        closeT = 0
        overlayOpacity = 0
        selectedRingIndex = nil // r39-5：第 5 件——重开环清掉上次点中的环卡上抬
        ringPhase = .open
        ringDragging = false // 上次拖动若被系统打断残留了 true，先清掉再起新拖动
        // r51（D5）：isRingDragging 写入已删（属性已删，无读取方）。
        ringOpenY = y
        closeGeneration += 1
        entryGeneration += 1
        // r33，第 5 条：展开 520ms（easeOutQuint 近似 timingCurve(0.22,1,0.36,1)），
        // 覆盖层 260ms 淡入（壳版 .mring transition opacity .26s）。
        // 动画必须等覆盖层以 entryT=0 首绘后再跑：同一事务里 phase=.open 与
        // entryT=1 一起提交时，覆盖层首帧就是 entryT=1、overlayOpacity=1，
        // 520ms 动画一次插值都不跑、环直接蹦出来（视频 f_001→f_002 的跳变根因；
        // f_002 在 0.25s 时卡片已是环尺寸、变暗已满，不是动画跑得快，是动画
        // 根本没跑）。下一显示帧之后再起动画：DispatchQueue.main.async 不够——
        // 它和本次提交跑在同一帧里，覆盖层首帧仍是最终值；睡 16ms（约一帧）
        // 保证 entryT=0 的首帧已经上屏，随后 520ms 逐帧展开。16ms 延迟肉眼
        // 不可见（520ms 的 3%）。代号用 entryGeneration（见声明处），
        // 不复用 closeGeneration。时长先取到局部量，闭包里不再碰 Self。
        let entryGen = entryGeneration
        let enterSec = Self.enterMs / 1000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard let self else { return }
            guard entryGen == self.entryGeneration,
                  self.ringPhase == .open else { return }
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: enterSec)) {
                self.entryT = 1
            }
            withAnimation(.easeOut(duration: 0.26)) {
                self.overlayOpacity = 1
            }
        }
        // r33，第 2 条：开环即预取锚点前后各 5 槽的封面（约 1.2 秒转量），
        // 不等卡片转进来才起取图。
        lastPrefetchCenterSlot = ringCenterSlot
        prefetchRingCovers(aroundCenterSlot: ringCenterSlot)
        // 展开这根手指不用抬起：直接记为拖动起点，继续拖就是转环。
        if beginDrag {
            ringDragStart(x: x)
        }
    }

    /// 收回：430ms（点空白 220ms 快收），收完 phase=.closed，平面带
    /// 220ms 后恢复自动走（r51：第 1 件——改回壳版 finishClose 同款
    /// resumeAt=now()+220ms；r46-6 的 2s 作废）。
    func closeRing(quick: Bool = false) {
        guard ringPhase == .open else { return }
        ringPhase = .closing
        stopRingSpring() // r36-8：收回时弹簧停掉，不让它在 closing 里继续推角
        closeGeneration += 1
        entryGeneration += 1 // r33，第 5 条：还没跑的 deferred 展开动画作废
        ringDragging = false
        // r51（D5）：isRingDragging 写入已删（属性已删，无读取方）。
        closeT = 0
        let ms = quick ? Self.quickCloseMs : Self.closeMs
        withAnimation(.timingCurve(0.32, 0, 0.67, 0, duration: ms / 1000)) {
            closeT = 1
        }
        // r39-5：第 5 件——壳版 renderRing 里覆盖层透明度 = 1 − easeInCubic(closeT)，
        // 与 closeT 同曲线；旧 .easeOut 先快后慢、与壳版反向。
        withAnimation(.timingCurve(0.32, 0, 0.67, 0, duration: ms / 1000)) {
            overlayOpacity = 0
        }
        let gen = closeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000) + 140_000_000)
            guard gen == self.closeGeneration else { return }
            self.ringPhase = .closed
            self.entryT = 0
            self.closeT = 0
            self.selectedRingIndex = nil // r39-5：第 5 件——环已收回，点中环卡的上抬清掉
            self.flatDwellUntil = Date().addingTimeInterval(Self.closeResumeMs / 1000)
            self.flatDwellReason = "close-done" // r34：看门狗日志报重停原因
        }
    }

    // MARK: 环拖动 / 松手

    /// 覆盖层手指刚落下（还没动）：取消待执行的松手收回 + 停弹簧
    /// （ring.js onOverlayDown → beginPress → clearHold 同款；
    /// 壳版 beginPress 在 pointerdown 当下就 `ring.target = null;
    /// ring.velocity = 0`——手指按住不动时弹簧不再推着环走；
    /// 拖动本身 5px 后才由 ringDragStart 接管，见 RingTouchView）。
    /// r37-9：旧写法只清收回代号、不停弹簧，松手弹簧跑着的时候换手
    /// 按住，环还在手指底下自己滑；现在落指即停，与壳版同顺序。
    func ringTouchBegan() {
        guard ringPhase == .open else { return }
        stopRingSpring()
        closeGeneration += 1
    }

    /// 覆盖层手指抬起且没拖起来（r33，第 3 条）：touchesBegan 已经把待执行
    /// 的松手收回取消了（closeGeneration+1），但这次触摸既没走
    /// ringDragEnded（<5px 没起拖）、又没走点按（pan 认出来了，tap 的
    /// require(toFail: pan) 不触发），不补一个收回定时器环就永远开着——
    /// 松手 1s 自动收的定时器在这里断了。手指抬起 = 一次新的松手，重新排 1s 收回。
    /// 纯点按不走这里（pan 没认出来 → tap 触发 → 点卡播歌/点空白快收）。
    func ringTouchEnded() {
        guard ringPhase == .open, !ringDragging else { return }
        scheduleHoldClose()
    }

    /// 环拖动的起点（r24：第 3 件后两个入口共用——平面带开环手指与
    /// 覆盖层新手指）。
    /// - `y`：拖动起点纵坐标（下滑退出用）；平面带入口不传，取开环点
    ///   `ringOpenY`（与旧 `stripTouchMoved` 的 strip-local y 同一坐标系）；
    ///   覆盖层入口传覆盖层本地 y（RingTouchView 的坐标原点与
    ///   "liziHome" 同在屏左上角，见 RingTouchView 注释）。
    /// 同时取消待执行的松手收回（代号 +1；ring.js beginPress clearHold 同款）。
    /// r37-9（换手滑不动的根因之一）：旧守卫是
    /// `guard ringPhase == .open, !ringDragging`——上一根手指的拖动若
    /// 在异常路径上结束（见 ringDragEnded 的守卫、RingTouchView 缺 .failed
    /// 出口），ringDragging 残留 true，新手指的每一次 ringDragStart 都被
    /// 挡在守卫外、永远锚不到新起点，ringDragMoved 只能用旧锚点（或直接
    /// 守卫拦住），环就跟不上新手。壳版 onPressMove 起拖时没有任何
    /// `!dragging` 守卫，每次起拖都无条件重锚 startAngle / x0 / samples
    /// （新 pointerdown 还先 detachPress 丢掉旧会话）；这里改成只守
    /// phase，起拖永远重锚——新手指接管旧会话，而不是被旧会话挡住。
    func ringDragStart(x: CGFloat, y: CGFloat? = nil) {
        guard ringPhase == .open else { return }
        stopRingSpring() // r36-8：弹簧没跑完就上手抓——先停弹簧再跟手，
        // 不然 display link 还在推角、手指也在推角，两边打架就是一顿一顿。
        ringDragging = true
        // r51（D5）：isRingDragging 写入已删（属性已删，无读取方）。
        ringStartAngle = angle
        ringStartX = x
        ringDragStartY = y ?? ringOpenY
        ringSamples = [(Date(), angle)]
        closeGeneration += 1
    }

    func ringDragMoved(toX x: CGFloat) {
        guard ringPhase == .open, ringDragging else { return }
        // r39-5：第 5 件——壳版 `if (s.n > 1)`——只有一张卡时不转（angle 钉在 0，
        // 见 ringDragEnded 的 n≤1 分支）；采样/带子同步/预取照常。
        if ringSlotCount > 1 {
            angle = ringStartAngle + (x - ringStartX) * ringPerPixel
        }
        let now = Date()
        ringSamples.append((now, angle))
        while ringSamples.count > 2,
              now.timeIntervalSince(ringSamples[0].time) > Self.sampleMs {
            ringSamples.removeFirst()
        }
        // r51：第 1 件——拖环不再同步带子（r33 联动已拆，改回套壳语义：环只转环，
        // 带子停在旧位置；收环 220ms 后从旧位置接着滚）。
        // r33，第 2 条：中心槽位变了就预取新中心前后各 5 槽的封面。
        let cs = ringCenterSlot
        if cs != lastPrefetchCenterSlot {
            lastPrefetchCenterSlot = cs
            prefetchRingCovers(aroundCenterSlot: cs)
        }
    }

    /// 松手：最近 110ms 角速度（限幅 ±1400°/s）投影目标槽位，
    /// 临界阻尼弹簧（stiffness 118、阻尼 2√118、1/240s 步长，
    /// 壳版 advanceRing 原样，见 startRingSpring）吸附到最近槽位中心；
    /// 随后保持 1000ms 再收回。
    /// r36-8：旧的 `withAnimation(.spring(response: 0.58,
    /// dampingFraction: 1.0))` 只对上了频率（2π/√118 ≈ 0.58s）——
    /// SwiftUI spring 吃不到初速度，松手那一刻 v 被扔掉、环先死停再爬
    /// 过去，与壳版「带着速度飞过去再稳稳停住」不是同一种手感；且它走
    /// 渲染服务器自己的计时，不是 1/240s 显式积分。现在初速度 v 直接
    /// 带进 startRingSpring（壳版 advanceRing 就是从 v 起步）。
    func ringDragEnded() {
        // r37-9：先清拖动旗、再判 phase——壳版 releaseRing 第一句就是
        // `s.dragging = false`，不带 phase 守卫；旧写法守卫在前，phase 已
        // 离开 .open 时（收回中/被打断）直接 return，ringDragging 永久置
        // true，下一根手指的 ringDragStart 被 `!ringDragging` 守卫挡住，
        // 换手后环再也滑不动。清旗在前，任何退出路径都到不了“旗子卡住”
        // 这一种死法；后面的速度/弹簧/收回仍只在 .open 时算。
        ringDragging = false
        // r51（D5）：isRingDragging 写入已删（属性已删，无读取方）。
        guard ringPhase == .open else { return }
        // r39-5：第 5 件——壳版 releaseRing 的 n≤1 分支——只有一张卡时 angle 钉 0、
        // 不算速度、不起弹簧，直接排 1s 收回（正在播放队列只有 1 首时命中）。
        if ringSlotCount <= 1 {
            angle = 0
            stopRingSpring()
            scheduleHoldClose()
            return
        }
        let now = Date()
        var v: CGFloat = 0
        if ringSamples.count > 1 {
            while ringSamples.count > 2,
                  now.timeIntervalSince(ringSamples[0].time) > Self.sampleMs {
                ringSamples.removeFirst()
            }
            let first = ringSamples[0]
            let last = ringSamples[ringSamples.count - 1]
            let span = last.time.timeIntervalSince(first.time)
            let idle = now.timeIntervalSince(last.time)
            if idle <= 0.080, span > 0.008 {
                v = max(-Self.maxVelocity,
                        min(Self.maxVelocity, (last.angle - first.angle) / CGFloat(span)))
            }
        }
        var projected = angle + v * Self.tau * 0.55
        // r43-4：第 4 件——本次拖动的净位移（相对起拖角；落点方向判定用，
        // 原先只在 |v|<1 的 nudge 分支里是局部量）。
        let moved = angle - ringStartAngle
        if abs(v) < 1 {
            if abs(moved) >= ringStep * 0.22 {
                projected += (moved > 0 ? 1 : -1) * ringStep * 0.28
            }
        }
        var targetAngle = -CGFloat(Int((-projected / ringStep).rounded())) * ringStep
        // r37-1（00:42:43 纠正：3D 环卡滑动按套壳版一比一）：壳版 releaseRing
        // 原式——松手速度方向与到目标槽位的方向不一致时速度清零
        // （`s.velocity = (dist !== 0 && Math.sign(v) !== Math.sign(dist)) ? 0 : v`）；
        // 旧写法把 v 原样带进弹簧：小甩刚越过槽位中心时，弹簧先带着反向初速度
        // 冲过目标再拉回来，与壳版「直接稳住」手感不同。清零放在吸附分支判断
        // 之前，与壳版同顺序（清零后再判 `|dist|<1e-6 && |v|<1` 直接钉死）。
        let distToTarget = targetAngle - angle
        if distToTarget != 0, v != 0, (v > 0) != (distToTarget > 0) {
            v = 0
        }
        // r43-4：第 4 件——环只许向左转：松手弹簧的落点不得在当前角的右侧，
        // 除非这次拖动本身就是向右的（手指净位移 moved > 0，或松手速度 v > 0——
        // 手指跟手，向右甩的惯性是用户自己的方向，不动）。
        // 其余情形（向左拖后没够半槽、手指基本停住）算出的右侧落点只是
        // “弹回原槽”，弹簧会带着环向右转、卡片从右缘退出；改成落到当前角
        // 左侧最近的槽位（floor），环只向左走、卡片只从左缘出、从右缘进。
        // 几何（第 ① 件）/上抬（第 ③ 件）/惯性/收回计时都不动，只改落点这一个数。
        // 注：向左小拖（<0.22 槽）松手后不再弹回原槽，改为前进一槽——
        // 弹回本身就是一次向右转，不弹回又会把环停在两槽之间、中心卡不正，
        // 只有前进一槽能同时满足“只向左”与“落槽居中”。
        if targetAngle > angle, v <= 0, moved <= 0 {
            targetAngle = floor(angle / ringStep) * ringStep
        }
        if abs(targetAngle - angle) < 1e-6, abs(v) < 1 {
            angle = targetAngle
            stopRingSpring()
        } else {
            // r36-8：显式弹簧（壳版 advanceRing），不用 SwiftUI spring。
            startRingSpring(target: targetAngle, velocity: v)
        }
        // r33，第 2 条：弹簧落点那首前后各 5 槽的封面提前取（落点槽位在
        // 弹簧动画里才走到；封面预取按落点槽位先走，不等弹簧走完）。
        // r51：第 1 件——onChange(of: angle) 的带子同步已删，弹簧只转环、不动带子。
        let targetSlot = Int((-targetAngle / ringStep).rounded())
        if targetSlot != lastPrefetchCenterSlot {
            lastPrefetchCenterSlot = targetSlot
            prefetchRingCovers(aroundCenterSlot: targetSlot)
        }
        // r51：第 1 件——松手补同步已拆（r47-2 的收尾同步作废，改回套壳语义）：
        // 松手只排 1s 收回，不动带子；带子停在旧位置，收环 220ms 后接着滚。
        scheduleHoldClose()
    }

    /// 松手弹簧驱动（r36-8，壳版 ring.js advanceRing 一比一）：
    /// CADisplayLink 每帧一调，帧内按 1/240s 子步半隐式欧拉积分，
    /// 只把帧末的角发出去渲染（壳版同款：advanceRing 子步、renderRing 一帧一次）。
    /// - 初速度就是松手那一刻的 v（限幅 ±1400°/s 已在 ringDragEnded 里夹过），
    ///   不像 SwiftUI spring 那样扔掉；
    /// - 停稳条件与壳版同款：越过目标、或 |target−angle| < 0.004 且
    ///   |velocity| < 0.03，停下时角钉死在目标槽位；
    /// - dt 按 link.timestamp 的真差算、上限夹 0.05s（壳版 ringFrame 同款），
    ///   丢帧后下一步自动补量，位移严格按时间走。
    func startRingSpring(target: CGFloat, velocity: CGFloat) {
        stopRingSpring()
        ringSpringTarget = target
        ringSpringVelocity = velocity
        ringSpringLastTimestamp = 0
        let proxy = RingSpringDisplayLinkProxy(model: self)
        let link = CADisplayLink(target: proxy, selector: #selector(RingSpringDisplayLinkProxy.fired(_:)))
        link.add(to: .main, forMode: .common)
        ringSpringProxy = proxy
        ringSpringLink = link
    }

    /// 停弹簧（新拖动上手、收回、模型释放时调；幂等）。
    func stopRingSpring() {
        ringSpringLink?.invalidate()
        ringSpringLink = nil
        ringSpringProxy = nil
        ringSpringTarget = nil
        ringSpringVelocity = 0
        ringSpringLastTimestamp = 0
    }

    /// display link 回调：1/240s 子步半隐式欧拉（壳版 advanceRing 原式）。
    func ringSpringFired(_ link: CADisplayLink) {
        guard let target = ringSpringTarget else { stopRingSpring(); return }
        let dt: Double
        if ringSpringLastTimestamp == 0 {
            dt = 1.0 / 60.0
        } else {
            dt = min(max(link.timestamp - ringSpringLastTimestamp, 0), 0.05)
        }
        ringSpringLastTimestamp = link.timestamp
        let prev = angle
        var remaining = dt
        while remaining > 0 {
            let h = min(remaining, Self.springStep)
            let accel = Self.springStiffness * (target - angle) - Self.springDamping * ringSpringVelocity
            ringSpringVelocity += accel * CGFloat(h)
            angle += ringSpringVelocity * CGFloat(h)
            remaining -= h
        }
        if (prev - target) * (angle - target) <= 0 ||
            (abs(target - angle) < 0.004 && abs(ringSpringVelocity) < 0.03) {
            angle = target
            stopRingSpring()
        }
    }

    /// 松手 1000ms 后收回；中途再拖动即作废（代号 +1）。
    func scheduleHoldClose() {
        closeGeneration += 1
        let gen = closeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard gen == self.closeGeneration,
                  self.ringPhase == .open, !self.ringDragging else { return }
            self.closeRing()
        }
    }

    // MARK: 环 ↔ 平面带联动（r33，用户 10:11/10:12：环跟着下面那排卡片走）
    // r51：第 1 件——联动的「带子同步」一半已拆（见下 syncFlatOffsetToRingCenter /
    // centerFlatOnSelected 删除注）；本节只剩封面预取 prefetchRingCovers。

    /// 环封面预取（r33，第 2 条）：环每转到新槽位才起取图的话，4 并发门
    /// （CoverFetchGate，见 Proxies.swift）约 2 张/秒的吞吐追不上 4 张/秒
    /// 的转速——视频里环 7 秒转约 30 首，f_010 起封面全丢（f_001–f_008
    /// 的封面是开环前平面带挂载时就取到的，环转到没取过的曲目就只剩占位）。
    /// 开环 + 中心槽位每变一次，提前把前后各 5 槽（约 1.2 秒转量）的封面
    /// 推进 CoverImageLoader：同一 URL 只拉一次、在飞任务复用、进缓存，
    /// 已缓存/在飞的调用是空操作，不重复烧流量；每 URL 一个 detached 任务
    /// 分头起取，不串行等（串行等的话 11 张图要 20 秒才排完队）。
    /// 门本身没卡住（max 4 并发、FIFO、抛错/取消都还槽，见 Proxies.swift），
    /// 只是吞吐追不上转速——预取 + 深色占位是本文件内能做的两件；
    /// 冷页一次转 30 首仍会跑赢 4 并发门，见交回诚实残留。
    func prefetchRingCovers(aroundCenterSlot cs: Int, radius: Int = 5) {
        guard itemCount > 0 else { return } // r43-2：第 2 件——条目数，曲目路与旧 tracks 同值
        let center = mod(anchorIndex + cs, itemCount)
        var urls: [URL] = []
        urls.reserveCapacity(radius * 2 + 1)
        for d in -radius...radius {
            let idx = mod(center + d, itemCount)
            if let url = itemCard(at: idx).coverURL { urls.append(url) } // r43-2：第 2 件——通用卡取封面，曲目路与旧 tracks[idx].coverURL 同值
        }
        for url in urls {
            Task.detached { _ = await CoverImageLoader.shared.image(for: url) }
        }
    }

    // r51：第 1 件——`syncFlatOffsetToRingCenter` 与 `centerFlatOnSelected`
    // 两个函数已整段删除（改回套壳语义）：环不再写 flatOffsetX，点卡不再居中；
    // 三处调用（ringDragMoved、ringDragEnded 末尾、覆盖层 onChange 弹簧阶段）
    // 与两处调用（syncInputs 跟随块、playTrack）随之一并删。r46-5 的
    // 「高亮跟环中心走」随之作废——高亮只跟在播曲目（syncInputs 的
    // `selectedFlatIndex = playingIndex`，r45-3；playTrack 的点中标记）。
    // prefetchRingCovers（封面预取）保留，不动。

    // MARK: 点播

    /// 点卡片播歌（r26-3D）：整份每日进队列、从点中的起播
    /// （壳版 `activate(i)` / `playQueue(items, i, true)` 同款）。
    /// 按下标播：`setQueue` 整队 map 成 QueueItem、currentIndex = index，
    /// 同一首歌在每日里出现两次时点第二张播的就是第二张（r25 U6 的
    /// 按下标/按 queueId 定位，在这里由 setQueue 的下标保证；环内
    /// queueId 分支随队列模式一起退役——环不再显示队列，见文件头 r26-3D；
    /// U6a–U6d 的 play(queueItem:) 应用点——播放器队列行、封面流——不动，
    /// 见 verification/r25.cjs 的 U6e 更新说明）。
    func playTrack(at index: Int, store: PlaybackStore) {
        guard (0..<itemCount).contains(index) else { return } // r43-2：第 2 件——条目下标，曲目路与旧 tracks.indices 同值
        selectedFlatIndex = index // r39-4：点中的卡整体上抬 1pt（r43-3；FlatRingCard 的 isSelected）
        // r51：第 1 件——点卡居中已拆（r48-3 / r47-2 的 centerFlatOnSelected 作废，改回套壳语义）：
        // 点卡只标记 selectedFlatIndex（上抬/高亮），不动 flatOffsetX；带子停在旧位置，
        // 收环 220ms 后从旧位置接着滚。集合卡点后换内容仍走 syncInputs 的从头显示（flatOffsetX=0）。
        // r43-2：第 2 件——通用路：点按走卡自带的 onTap（调用方填好的原行为），
        // 不走 setQueue（歌单/专辑/电台卡本来就不是曲目，拼不出队列）。
        if isGeneric {
            genericCards?[index].onTap?()
            return
        }
        // r38-fix ①：点卡切歌保留待播「下一首」标记（setQueue 整队重建时
        // 按曲目身份重映射新 queueId，见 PlaybackStore.setQueue；
        // 搜索/歌单/歌手等其他 setQueue 调用点仍清空，语义不动）。
        store.setQueue(tracks, startAt: index, title: queueTitle, preservePlayNext: true)
    }

    /// 点环卡：播歌 + 收回环（壳版 selectItem 同款）。
    /// r39-5：第 5 件——点中的环卡记 selectedRingIndex，整体上抬 1pt（r43-3）
    /// （与平带卡 selectedFlatIndex 同款；收回淡出里可见，环收完清掉）。
    func tapRingCard(trackIndex: Int, store: PlaybackStore) {
        selectedRingIndex = trackIndex
        // r48-3：带子居中已收进 playTrack（平带/环、曲目/通用全路），
        // 这里不再另写一份（r47-2 的 `if !isGeneric` 居中随之归并：
        // 通用路点卡同样跟到被选卡）。
        playTrack(at: trackIndex, store: store)
        closeRing()
    }

    // MARK: 环几何（纯函数，供覆盖层逐卡计算）

    struct RingSlot: Identifiable {
        var id: Int { s }
        /// 整数槽位（相对锚点）。
        let s: Int
        /// 该槽相对正前方的世界角（度），-86.5…+86.5。
        let world: CGFloat
        let trackIndex: Int
    }

    /// 可见槽位（r35-8，拖影根因）：中心槽前后各两格（world ±80°），
    /// 不再是 ±1 格。旧 ±1 的问题：槽位在 world ±60°（facing 0.5、
    /// facingOpacity = 1）时硬弹出/消失——拖动中每转 40° 就有一张
    /// 全不透明的卡在屏内凭空消失、对面凭空出现一张，看着就像把卡片
    /// 甩出去丢掉（用户 19:07「像把卡片丢掉的拖影」）；套壳 ring.js
    /// 是 9 个槽位固定身份绕圆柱转、只按 facing 淡出，卡片从不在屏内
    /// 凭空出现/消失。改 ±2 后槽位进出窗口发生在 |world| = 86.5°
    /// （facing 0.06、facingOpacity ≈ 0）处，再经 0.06–0.30 smoothstep
    /// 淡入/淡出——圆柱体一直转，拖动就是干净的圆柱转动。
    /// 静止时多露的两格在 world ±80°、透明度约 0.46、贴在屏边（壳版同款
    /// 边缘淡卡；旧「一次只见 3 张」是 r31 按 f_050 定的，淡入淡出
    /// 的代价就是边缘多两张淡卡）；|world| ≤ 86.5°（facing > 0.06）
    /// 仍作第二道防线，同一首歌只出现一次（曲目 < 5 首时不复制，
    /// 壳版 n = min(曲数, 环容量) 同款）。
    /// r39-5：第 5 件——±2 是 step=40° 时的数（2×40=80°）；step 换成壳版公式后
    /// 窗口按角度算：span = ceil(86.5/step)（竖屏约 35° → 3 格、
    /// 横屏约 15.7° → 6 格），|world| ≤ 86.5° 的过滤仍在——step=40°
    /// 时 span=3、±3 格全被过滤，与旧 ±2 同集。
    /// 拖动 1:1 / 松手惯性 + 弹簧 / pitch / 压暗 / 后仰 / 位置 / 绑定
    /// 一字不动（见 ringDragMoved / ringDragEnded）；文件里没有
    /// rasterize / .drawingGroup / .blur（拖影不是栅格化糊的），
    /// 拖动路径上也没有 .animation（没有动画滞后/过冲）。
    func visibleSlots() -> [RingSlot] {
        guard itemCount > 0 else { return [] } // r43-2：第 2 件——条目数，曲目路与旧 tracks 同值
        let q = -angle / ringStep
        let center = Int(q.rounded())
        var seen = Set<Int>()
        var out: [RingSlot] = []
        let span = max(2, Int(ceil(86.5 / ringStep))) // r39-5：第 5 件——窗口按角度算
        for s in (center - span)...(center + span) {
            let world = (CGFloat(s) - q) * ringStep
            guard abs(world) <= 86.5 else { continue }
            let idx = mod(anchorIndex + s, itemCount)
            guard !seen.contains(idx) else { continue }
            seen.insert(idx)
            out.append(RingSlot(s: s, world: world, trackIndex: idx))
        }
        return out
    }

    /// 展开/收回中的有效半径（壳版 renderRing：R·(0.42+0.58·entry)·(1-0.66·close)）。
    func effectiveRadius() -> CGFloat {
        ringRadius * (0.42 + 0.58 * entryT) * (1 - 0.66 * closeT)
    }

    /// 相机缩放（壳版：(0.74+0.26·entry)·(1-0.55·close)）。
    func cameraScale() -> CGFloat {
        (0.74 + 0.26 * entryT) * (1 - 0.55 * closeT)
    }

    /// 正面朝向 0…1（world=0 正对，world=±90 侧对）。
    func facing(forWorld world: CGFloat) -> CGFloat {
        cos(world * .pi / 180)
    }

    /// 背面藏、近背面 smoothstep 淡出（壳版 renderRing 同款）。
    func facingOpacity(facing: CGFloat) -> Double {
        if facing <= 0.06 { return 0 }
        if facing < 0.30 {
            let q = Double((facing - 0.06) / 0.24)
            return q * q * (3 - 2 * q)
        }
        return 1
    }

    /// 远端压暗（壳版：0.55·((1-facing)/2)^1.25）。r36-8 起环卡又只走
    /// 这一层平色（r33 的远缘渐变 shadeFarEdge 已删，见下条注释）。
    func shadeOpacity(facing: CGFloat) -> Double {
        0.55 * pow(Double((1 - facing) / 2), 1.25)
    }

    /// r36-8，删：`shadeFarEdge`（r33，第 1 条：沿卡面横向渐变，40° 槽位
    /// 远缘 0.42）已删——它是「正交旋转没有梯形」时的视觉补偿；r33 同轮
    /// 已把 perspective 从 0 改成卡高/P、梯形回来了，且壳版视频里侧卡
    /// 是亮的（同曲《回到你身边》壳版卡面亮度 135、原生 45，3 倍差的
    /// 大头就是这层 0.42 + 压在卡上的全屏压暗）。壳版 shade 只有 flat
    /// 公式（`shadeOpacity`，40° 时 3.8%），侧卡明暗只走这一层。

    /// 卡内透视（r33，第 1 条）：rotation3DEffect 的 perspective 参数，
    /// 目标是壳版透视距离 P=3.2R（标准档 ≈697pt）——侧卡按这个距离再压一次
    /// 近大远小，近缘比远缘宽约 12%，梯形就是圆柱感。r31 用 0（正交）是
    /// 因为 0.5 远超 P、梯形变折叠；这里取 perspective ≈ 卡高 / P
    /// （标准档 195/697 ≈ 0.28，三档都在 0.27–0.29）：SwiftUI 的 perspective
    /// 是相对量、与 CSS perspective:px 没有精确等价换算（见 r31 注），
    /// 0.5 已远超 P，0.28 是按卡高换算的近似值——布局尺寸不受影响
    /// （rotation3DEffect 只改渲染不改布局），错也不会崩版，只会梯形
    /// 稍强或稍弱，真机确认强度，见 r33.cjs 断言建议。
    var ringCardPerspective: CGFloat {
        ringCardHeight / ringPerspective
    }

    /// 透视缩放（r31 真圆柱）：scale = P/(P−z)，与 projectedX 共用同一个
    /// 透视因子 `perspectiveFactor`（旧式 3.2/(3.2+(1−facing)) 就是它
    /// 在 P=3.2R、z=R·(facing−1) 下展开后的样子，数值不变；现在改成
    /// 按 world 角委托，展开/收回中跟有效半径走，与 projectedX 严格同源，
    /// 不再各算各的）。
    func depthScale(forWorld world: CGFloat) -> CGFloat {
        perspectiveFactor(forWorld: world)
    }

    /// 某槽位在圆柱面上的 z 深度（r31 真圆柱，相对正前方卡面，≤0）：
    /// z = R·(cos(world)−1)；正前方 0，world=±40° 时约 −0.234R（标准档
    /// 约 −51pt），world=±80° 时约 −0.826R。r30 没有这个量——所有卡
    /// 都在 z=0 平面上，只剩原地旋转 + perspective 0.5 压扁，看着是折过去。
    /// 展开/收回中跟有效半径走（R 收缩时深度同缩，与 projectedX 同款）。
    func cylinderZ(forWorld world: CGFloat) -> CGFloat {
        effectiveRadius() * (facing(forWorld: world) - 1)
    }

    /// 透视因子 P/(P−z)（r31 真圆柱）：正前方 1，越靠两侧越小——卡片离
    /// 相机越远显得越小、也往中心收。P = ringPerspective（3.2R），
    /// z = cylinderZ（有效半径下，壳版 renderRing 的 CSS 透视等价物；
    /// 展开时 entry<1、z 绝对值小，因子接近 1，环从平面里长出来）。
    func perspectiveFactor(forWorld world: CGFloat) -> CGFloat {
        let p = ringPerspective
        return p / (p - cylinderZ(forWorld: world))
    }

    /// 透视投影后的横向偏移（r31 真圆柱）：x = R·sin(world)·P/(P−z)。
    /// r30 的 x = R·sin(world) 没除透视：侧卡摆得太开（标准档 40° 时
    /// 140pt，真投影约 131pt），又没有 z 深度，只剩原地旋转，看着是折叠；
    /// 现在侧卡既被推到圆柱面后面去（cylinderZ），横向又按透视收进，
    /// 绕着圆柱转过去才是转圈圈。
    func projectedX(forWorld world: CGFloat) -> CGFloat {
        effectiveRadius() * sin(world * .pi / 180) * perspectiveFactor(forWorld: world)
    }

    /// r39-5：第 5 件——`tiltDrop`（相机 -5° 下坠，r26-3D：
    /// 某槽位的 z = R·cos(world)，下坠跟着 facing 走，正前方最大、越靠两侧越小）
    /// 已删：它让侧卡比中心卡高约 4.7pt（40° 时），转动时卡片上下参差；
    /// 用户新补「转动时全部卡片保持一条线」。相机 -5° 只剩卡面后仰那道
    /// X 轴旋转（ringLayerInStrip 的 rotation3DEffect -5°），纵坐标不再
    /// 按 facing 各偏——全部卡片取中心卡同一纵坐标（见 ringCardCenterYLocal）。

    /// 环中心纵坐标（r34 重写：渲染不再用它，见 ringCardCenterYLocal）。
    /// 只剩变暗中心用：变暗光晕的中心 = 环视觉中心 = 中心卡的卡中心
    /// （= stripCenter.y，见 ringCardCenterYLocal 的推导，再 −3pt 是旧的
    /// 量取余量，见下）。stripCenter 还没量到时回落屏高 ×0.62
    /// （r24 同款；r51 D5：`topEdge` 参数已删，体内原只有 `_ = topEdge`）。
    /// r31 的教训仍在：不要把 ring.js 的 cy 上下限夹取搬回来——Hero 拖大后
    /// 带心远超旧上限，夹取就是把环钉在固定高度、与带子脱节。
    /// 横竖屏判定（r47-3：第 3 件——syncInputs 同步进来的实测屏宽/高；
    /// 没量到时回落真屏基准 UIScreen）。
    var isLandscapeScreen: Bool {
        if screenHeight > 0 { return screenWidth > screenHeight }
        return ringBasisWidth > ringBasisHeight
    }

    /// r47-3：第 3 件——横屏时环卡中心纵坐标夹到屏内（覆盖层本地坐标，
    /// 原点 = ScrollView 顶，高度 = 覆盖层 geo 高；渲染、命中测试、
    /// 变暗中心、压暗开洞都走同一份夹取后的值）。
    /// 横屏默认面板只有 128pt、带子中心在屏底之下：按带子锚点算出的中心
    /// 会把整环挂在屏外（只剩盖顶露在屏底边），用户眼里就是「没出 3D」。
    /// 夹取区间：环顶 ≥ 8、环底 ≤ 提示行顶（屏高 ×0.94）− 8；带子在屏内
    /// 时夹取不触发，环仍钉在带子上（原地变 3D 不变）；屏太矮、区间倒挂
    /// 时不夹。竖屏一字不动（只在横屏分支里夹）。
    func clampedRingCenterY(_ y: CGFloat, screenHeight: CGFloat) -> CGFloat {
        guard isLandscapeScreen, screenHeight > 0 else { return y }
        let half = ringCardHeight / 2
        let top = half + 8
        let bottom = screenHeight * 0.94 - 8 - half
        guard top < bottom else { return y }
        return min(max(y, top), bottom)
    }

    // r51（D5）：topEdge 参数已删——体内只有 `_ = topEdge`，无读取方；调用点同步去掉该实参。
    func ringCenterY(screenHeight: CGFloat) -> CGFloat {
        // r47-3：第 3 件——横屏时变暗中心跟夹取后的环中心走（与卡片同位置，
        // 不然压暗洞与卡片错位、卡片被压暗）；竖屏原值不动。
        // ringCardCenterScreenY 的回落分支会调回 ringCenterY，但只在
        // stripCenter.y == 0 时调；这里只在 stripCenter.y > 0 时调它，
        // 不成环。stripCenter 还没量到时直接夹取回落值。
        if isLandscapeScreen {
            if stripCenter.y > 0 {
                return ringCardCenterScreenY(screenHeight: screenHeight) - 3
            }
            return clampedRingCenterY(screenHeight * 0.62, screenHeight: screenHeight) - 3
        }
        return stripCenter.y > 0 ? stripCenter.y - 3 : screenHeight * 0.62
    }

    /// 环卡中心纵坐标（带内局部坐标，r34，第 2/4 件：环就定在平带卡片的位置）。
    /// 带内原点 = 带顶，带高 flatHeight = flatCard + 52 + 1；平带盖面中心在
    /// 1 + flatCard/2（r43-3：卡片顶距带顶 1pt 上抬顶空）。环卡是 VStack（封面 ringCard + 5 + 歌名 + 5 + 歌手，
    /// 总高 ringCardHeight = ringCard + 46），盖面中心比卡中心高
    /// (ringCardHeight - ringCard) / 2 = 23pt。
    /// 中心卡盖面中心对齐平带盖面中心：
    ///   卡中心 = 1 + flatCard/2 + 23
    /// （r43-3：开头的 1 是上抬顶空，见上；没有它环盖面会比平带盖面高 1pt，
    /// 开环瞬间锚点卡跳位）。
    /// r39-5：第 5 件——全部卡片同一纵坐标（用户新补：转动时卡片保持一条线，
    /// 不上下错位、不参差）：旧公式 `- tiltDrop(1.0) + tiltDrop(facing)` 让侧卡
    /// 比中心卡高约 4.7pt（40° 时），已删；world 角不再影响纵坐标，参数随之删掉。
    /// 展开/收回中卡中心全程钉在 flatCard/2（只长尺寸、不挪位置——就是“原地变成 3D”）。
    /// 旧锚点 cy = stripCenter.y 的问题：它把卡中心当成盖面中心，
    /// 自带 23pt 上偏（r33 视频实测环盖比平盖高约 118pt，其中 23pt
    /// 是这笔账，剩下约 95pt 是存下来的 stripCenter 本身不准——见文件头 r34）。
    /// 本函数只用 flatCard，不读 stripCenter：渲染不再依赖
    /// 存下来的锚点，带子在哪、环就在哪。
    func ringCardCenterYLocal() -> CGFloat {
        // r43-3：+1pt 上抬顶空（平带卡片顶距带顶 1pt），环盖面中心跟着下移
        // 1pt，环开时盖面与平带盖面对齐（原地变 3D 不跳位）。
        Self.selectedLift + flatCard / 2 + (ringCardHeight - ringCard) / 2
    }

    /// 环卡中心纵坐标（屏坐标 / liziHome 坐标，点按命中用，与渲染同公式）：
    /// 中心卡卡中心 = 带顶 + 平盖中心 + 23pt 文字段（带顶 = stripCenter.y -
    /// flatHeight/2）；r39-5：第 5 件——各槽同一纵坐标，不再按 tiltDrop 偏。
    /// stripCenter 还没量到时中心卡卡中心回落 ringCenterY（屏高 ×0.62 那条），
    /// 命中盒跟着变暗中心走，不拿 y=0 去比。
    func ringCardCenterScreenY(screenHeight: CGFloat) -> CGFloat {
        let centerCardY: CGFloat
        if stripCenter.y > 0 {
            // r43-3：+1pt 上抬顶空（与 ringCardCenterYLocal 同款），命中盒
            // 跟渲染走，点按盒与眼睛看到的卡片位置一致。
            centerCardY = stripCenter.y - flatHeight / 2 + Self.selectedLift + flatCard / 2 + (ringCardHeight - ringCard) / 2
        } else {
            centerCardY = ringCenterY(screenHeight: screenHeight) // r51（D5）：topEdge 实参随参数删除
        }
        // r47-3：第 3 件——横屏夹到屏内（见 clampedRingCenterY；竖屏原值不动）。
        // 命中测试与覆盖层渲染都走这里，夹取后两边同值，点按盒与卡片一致。
        return clampedRingCenterY(centerCardY, screenHeight: screenHeight)
    }

    /// 面板横向范围（r31 真圆柱：halfWidth 不再用于裁切——r30 v5 图的
    /// 面板圆角裁切作废，实拍 f_050/f_060/f_070 里侧卡都溢出面板到屏边，
    /// 环层改全屏宽；r51 D5：halfWidth 已删，全仓无读取方，只保留作参考
    /// 的那一份也已确认无人读——现只返回面板中心 x）：
    /// 面板与带子同中心（stripCenter.x）。带子还没量到（stripCenter.x = 0）
    /// 时回落屏宽/2（与旧 centerX 回落同值；旧的半宽回落「屏宽/2 − 16」
    /// 随 halfWidth 一并删）。
    /// - 返回：面板中心 x，liziHome 坐标。
    func panelRect(screenWidth: CGFloat) -> CGFloat {
        stripCenter.x > 0 ? stripCenter.x : screenWidth / 2
    }

    /// 点按命中：取包含该点、离正前方最近的卡（ring.js onPressUp 点选同款，
    /// 用包围盒近似旋转后的卡）。
    /// r34：纵向锚点与渲染同公式（`ringCardCenterScreenY`：中心卡卡中心 =
    /// 带顶 + 平盖中心 + 23pt 文字段；r39-5：第 5 件——各槽同一纵坐标，
    /// 不再按 tiltDrop 偏）——命中盒与
    /// 眼睛看到的卡片位置一致；旧的 `ringCenterY + tiltDrop` 是错的
    /// （它把卡中心当成盖面中心，自带 23pt 上偏，见 ringCardCenterYLocal）。
    /// r31 真圆柱：横向锚点与渲染同款——panel.centerX（环跟着面板走；
    /// 旧的 screenWidth/2 与渲染锚点不是同一个，面板偏移时点按盒会错位），
    /// 横向位置与渲染同款 projectedX（透视投影后的位置，不是 R·sin），
    /// 面板外拦截删掉（侧卡溢出面板到屏边，溢出部分看得见、点得到）。
    // r51（D5）：topEdge 参数已删——体内只有 `_ = topEdge`，无读取方；三个调用点同步去掉该实参。
    func hitTestRingCard(at point: CGPoint, screenWidth: CGFloat, screenHeight: CGFloat? = nil) -> Int? {
        _ = screenWidth // r46-1：第 1 件——回落中心改走真屏基准（下行），调用方传的覆盖层 geo 宽（约 750pt）不再用
        let cx = panelRect(screenWidth: ringBasisWidth) // r51（D5）：halfWidth 已删，panelRect 现直接返回中心 x；r46-1 回落同前：stripCenter 没量到时中心按真屏宽/2（437pt）
        var best: (index: Int, world: CGFloat)?
        for slot in visibleSlots() {
            let x = cx + projectedX(forWorld: slot.world)
            let slotCy = ringCardCenterScreenY(screenHeight: screenHeight ?? 0)
            let halfW = ringCard * 0.55
            let halfH = ringCardHeight / 2
            if abs(point.x - x) <= halfW, abs(point.y - slotCy) <= halfH {
                if best == nil || abs(slot.world) < abs(best!.world) {
                    best = (slot.trackIndex, slot.world)
                }
            }
        }
        return best?.index
    }

    private func mod(_ v: Int, _ m: Int) -> Int {
        ((v % m) + m) % m
    }
}

/// 平面带按压判定（r40：三种——没判向、已开环、已交还 ScrollView；
/// r39-5 的 `.scrollingFlat`（横向手滚跑马带）随横向拖动开环恢复而删掉，
/// 上滑开环一并删掉，改回 r24）。
struct StripPress {
    var startX: CGFloat
    var startY: CGFloat
    var decided: StripDecision

    init(startX: CGFloat, startY: CGFloat, decided: StripDecision) {
        self.startX = startX
        self.startY = startY
        self.decided = decided
    }
}

enum StripDecision {
    case undecided
    case openedRing
    case handedToScroll
}

// MARK: - 平面带（常态）

struct HomeCoverRingView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @ObservedObject var model: HomeCoverRingModel

    /// 每日推荐曲目（调用方传 `viewModel.daily.map { $0.track }`）。
    var dailyTracks: [Track] = []
    var isLoadingDaily = false
    /// 每日推荐 spinner 是否可见（调用方传 `viewModel.dailySpinnerVisible`，
    /// r35-9：250ms 后仍未回来才亮）。
    var dailySpinnerVisible = false
    var dailyEmptyReason: String?
    /// 跑马带速度（调用方传 `viewModel.marqSpeedPxPerSecond`，默认 24）。
    var marqueeSpeed: CGFloat = 24
    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 面板深场（调用方传 HomeView 的专辑取色 field；默认深场）。
    var panelIsDark = true
    /// r36：点卡播歌时带上的队列标题（透传给模型 → setQueue(title:)；
    /// 搜索带传 playback.queueTitle，丢了它搜索置顶行就没了）。
    /// 每日推荐 / 榜单详情那路不传（nil）。
    var queueTitle: String? = nil
    /// r37-1：面板卡片只放封面（默认 false；HomeView 每日推荐那路传 true，
    /// 榜单详情那路也传 true——面板里的卡都走这条；歌单详情页那路不传，
    /// 卡片仍带歌名/歌手）。
    /// r39-4：第 4 件起 coverOnly 不再藏卡下两行字——`FlatRingCard` 在
    /// 两种模式下卡下都画歌名 + 演唱者，带高也不再按 coverOnly 分支
    /// （模型 `flatHeight` 恒为卡宽 + 两行字高 + 1pt 上抬顶空；r43-3）。
    /// coverOnly 现在只剩一个作用：封面还没显示出来时的歌名占位
    /// （盖在封面框里的那两行）只在 coverOnly 时出现；3D 环卡
    /// （`RingCardView`）不受 coverOnly 影响——00:42:43 纠正：1:1 复刻只限
    /// 3D 环卡，环卡按套壳版（封面 + 歌名）显示，标题常在。
    /// r37-1 追加（用户 2026-11-22 00:39 显示逻辑，长期规则）：
    /// 封面没加载出来时卡片先显示歌名/标题文字占位（盖在封面框上，
    /// 用户能先滑动、认出是哪首歌），封面加载出来后只渲染封面图、
    /// 不显示歌名；占位只在封面未显示时出现，不变常驻标题。
    /// 无封面 URL 的曲目永远无图可显，占位标题会一直显示（唯一能认出歌的办法）。
    var coverOnly = false
    /// r36（用户 21:44）：榜单详情那路不显示入口提示行（「左右拖动展开 3D 环 ·
    /// 拖动旋转」，r40 改口径）——详情页下面不加任何提示文字。每日推荐 / 搜索带
    /// 那路默认 false，提示行照旧。
    var hideEntryHint = false
    /// r39-5：第 5 件——实测屏宽（调用方传外层 GeometryReader 的 outer.size.width；
    /// 模型 ringCard/ringStep/ringRadius 全从它现算）。默认 0 =
    /// 没传，走旧 tier 分档（歌单详情页那路以外不应出现）。
    var screenWidth: CGFloat = 0
    /// r43-1：第 1 件——实测屏高（调用方传外层 GeometryReader 的 outer.size.height；
    /// 只判横竖屏，模型环卡宽 / 平面卡宽的横屏分支读它）。默认 0 = 没传，
    /// 环卡回落旧公式、平面卡回落 tier 分档。末位存储属性，调用点放最后。
    var screenHeight: CGFloat = 0
    /// r43-2：第 2 件——通用卡（rail 四栏 + 榜单目录，见 `HomeRingCard`）；
    /// nil = 曲目路（每日/正在播放/榜单详情/歌单详情，旧行为）。末位存储属性，
    /// 调用点放在 screenHeight 之后。注意：PlaylistDetailView 那路仍只传到
    /// screenHeight 为止，默认值 nil 让它继续走曲目路。
    var cards: [HomeRingCard]? = nil

    var body: some View {
        Group {
            if model.itemCount == 0 { // r43-2：第 2 件——条目数，曲目路与旧 model.tracks.isEmpty 同值
                if model.dailySpinnerVisible {
                    loadingView
                } else if model.isLoadingDaily {
                    // r35-9：250ms 内还没回来——旧内容没有（tracks 空），
                    // 也不亮 spinner，只留一块空白占位，不闪「暂无推荐内容」。
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: model.flatHeight, alignment: .center)
                } else {
                    emptyView
                }
            } else {
                // 平面带 + 入口提示行（r22c）：提示行是环的可见入口
                // （r28：「展开 3D 环」按钮已删，点按开环不在触发里；
                // 只留提示文字 + 平面带横向拖动开环，r40 改回 r24）。
                // r28：外面一块更深的圆角底（黑 0.18）——39.6s 视频 f_001
                // 里卡行就在一块比面板再暗一档的圆角底上。
                VStack(alignment: .leading, spacing: 6) {
                    flatStrip
                    if !hideEntryHint {
                        entryHintRow
                    }
                }
                .padding(10)
                // r36-8，第 2 条：带子下移 stripTopInset（24pt）——壳版顶栏底
                // 到环顶约 133pt，原生约 110pt；环在面板内偏高、贴着顶栏。
                // 平带与环同在 flatStrip 里，一起下移（r34 绑定不动）；
                // 面板封顶账里有约 36–43pt 余量，24pt 不顶出提示行。
                .padding(.top, HomeCoverRingModel.stripTopInset)
                // r30 v5：环开着时平面带彻底让位（壳版
                // `body.is-ring .mstrip { opacity: 0 }` 同款，透明度跟
                // overlayOpacity 走：展开 0.26s 淡出、收回跟 closeT 淡入），
                // 环下面不再透出多余的专辑卡。
                // r34：第 4 件——透明度不再挂在整个 VStack 上：环层已经
                // 搬进 flatStrip，再挂父级透明度会把环乘到 0。淡出只挂
                // 在平带容器（flatStrip 内）与入口提示行（entryHintRow），
                // 深色圆角底座不淡出（视频里环就坐在那块底座上）。
                // opacity 不动布局，stripCenter / stripSize 照常量，
                // 环的纵向锚点不受影响。
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.18))
                )
            }
        }
        .onAppear { sync() }
        .onChange(of: dailyTracks.map(\.id)) { _ in sync() }
        .onChange(of: cards?.map(\.id) ?? []) { _ in sync() } // r43-2：第 2 件——通用卡换了（entriesView/openedView 切换、切来源）即重同步
        .onChange(of: playback.currentTrack) { _ in sync() }
        .onChange(of: isLoadingDaily) { _ in sync() }
        // r37-6：旧 onChange 清单漏了 dailySpinnerVisible——ViewModel 在
        // 加载开始 250ms 后才把它翻成 true，那时 isLoadingDaily 早已是
        // true（无变化）、dailyTracks 也没变，没有任何一次 sync() 会把
        // 新的 spinner 旗同步进模型，模型就一直以为 spinner 不可见；
        // 反过来加载结束时若只有 spinner 旗变、其余字段不动，模型也会
        // 残留旧的加载文案。补上这一行，加载态三件套（tracks/loading/
        // spinner/reason）才算同步齐。
        .onChange(of: dailySpinnerVisible) { _ in sync() }
        .onChange(of: dailyEmptyReason) { _ in sync() }
        .onChange(of: marqueeSpeed) { _ in sync() }
        .onChange(of: tier) { _ in sync() }
        .onChange(of: screenWidth) { _ in sync() } // r39-5：第 5 件——转屏改宽即重算环几何
        .onChange(of: screenHeight) { _ in sync() } // r43-1：第 1 件——转屏改高即重算横竖屏几何
        .onChange(of: panelIsDark) { _ in sync() }
        .onChange(of: queueTitle) { _ in sync() }
        .onChange(of: coverOnly) { _ in sync() }
        .accessibilityLabel("封面环")
    }

    /// r26-3D：只同步每日推荐 + 在播曲目（开环锚点用）；队列不再同步
    /// （环不再显示队列，播歌不改变带子内容；切平台 → daily 变 → sync
    /// 换内容）。`playback.currentTrack` 变了才重算在播键——切歌不重置
    /// 带子（id 集合没变，syncInputs 里不重置、不关环）。
    private func sync() {
        model.syncInputs(
            daily: dailyTracks,
            isLoading: isLoadingDaily,
            spinnerVisible: dailySpinnerVisible,
            emptyReason: dailyEmptyReason,
            playing: playback.currentTrack,
            speed: marqueeSpeed,
            tier: tier,
            screenWidth: screenWidth, // r39-5：第 5 件
            screenHeight: screenHeight, // r43-1：第 1 件
            panelIsDark: panelIsDark,
            queueTitle: queueTitle,
            coverOnly: coverOnly,
            cards: cards // r43-2：第 2 件——通用卡（nil = 曲目路）
        )
    }

    // MARK: 加载 / 空态（DailyMarqueeView 同款文案）

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
            Text("正在拉取每日推荐…")
                .font(.liziBody(size: LiziTokens.size13))
                .foregroundColor(model.panelIsDark ? .white.opacity(0.62) : LiziTokens.ink3)
        }
        .frame(maxWidth: .infinity, minHeight: model.flatHeight, alignment: .center)
    }

    private var emptyView: some View {
        Text(model.dailyEmptyReason ?? "暂无推荐内容。")
            .font(.liziBody(size: LiziTokens.size13))
            .foregroundColor(model.panelIsDark ? .white.opacity(0.62) : LiziTokens.ink3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: model.flatHeight, alignment: .center)
            .padding(.horizontal, 24)
    }

    // MARK: 平面跑马带

    /// 平面带 + 入口提示行。
    ///
    /// 触摸走 `StripTouchView`（UIKit UIPanGestureRecognizer，见文件尾）：
    /// SwiftUI `.simultaneousGesture(DragGesture)` 在真机上拦不住 ScrollView
    /// 的竖滑——上滑开环的手势会被页面滚动抢走，环打不开（r21 的根因）。
    /// 触摸层盖在卡片上方（卡片不再是 Button，点按由识别器的 tap 接管，
    /// VoiceOver 激活走各卡的 `.accessibilityAction`）。
    private var flatStrip: some View {
        ZStack(alignment: .topLeading) {
            // 平带容器（r34，第 4 件）：裁切 + 淡出只留在这里——
            // 环层搬进带子后不再是它的父级，不会被父级透明度乘到 0、
            // 也不会被它的 `.clipped()` 切掉溢出带子的侧卡。
            // 两份 HStack 循环（flatOffsetX 在 (-setWidth, 0] 里打转）
            // 与旧版一字不改。
            ZStack(alignment: .topLeading) {
                HStack(spacing: model.flatGap) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: model.flatGap) {
                            ForEach(0..<model.itemCount, id: \.self) { i in // r43-2：第 2 件——条目数，曲目路与旧 model.tracks.indices 同值
                                FlatRingCard(card: model.itemCard(at: i), width: model.flatCard, isDark: model.panelIsDark, coverOnly: model.coverOnly, isSelected: model.selectedFlatIndex == i) { // r39-4：点中态传进卡片，上抬 1pt（r43-3）
                                    model.playTrack(at: i, store: playback)
                                }
                            }
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: FlatSetWidthKey.self, value: geo.size.width)
                            }
                        )
                    }
                }
                // r43-3：顶空 1pt（点中上抬预留）——平时卡片顶距带顶 1pt，
                // 点中的那张 offset -1 回到带顶；不留这 1pt，点中卡的卡顶会
                // 被下面 `.clipped()` 裁掉 1pt。带高 flatHeight 里已含这 1pt，
                // 卡下两行字不顶出带底。
                .padding(.top, HomeCoverRingModel.selectedLift)
                .offset(x: model.flatOffsetX)
                .onPreferenceChange(FlatSetWidthKey.self) {
                    // r34，第 1 件——布局完成前偏好先报 0，旧代码直接写成
                    // 0+16=16，带子只能在 16pt 里打转、看着就是冻住。
                    // 小于一份宽度只可能是布局前的残值，忽略，等布局完成
                    // 后的足额上报（syncInputs 里同一道兜底，见模型）。
                    let w = $0 + model.flatGap
                    if w >= CGFloat(model.itemCount) * (model.flatCard + model.flatGap) { // r43-2：第 2 件——条目数，曲目路与旧 model.tracks.count 同值
                        model.flatSetWidth = w
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: model.flatHeight, alignment: .top)
            .clipped()
            .opacity(1 - model.overlayOpacity)
            // 环层（r34，第 2/4 件）：就地环——不是覆盖层，是带子里的
            // 另一层；与平带共用同一份条目（model.itemCard，曲目路是曲目、
            // 通用路是通用卡）、同一套 visibleSlots/angle/anchorIndex、同一个容器。环闭合时不挂载，透明度跟
            // overlayOpacity（展开 0.26s 淡入、收回跟 closeT 淡出）。
            // 侧卡溢出带子贴到面板边是设计（壳版同款），外层 ZStack
            // 不裁切；面板圆角底座在 body 的 VStack 上，不裁内容。
            // r47-3：第 3 件——横屏时环卡改挂全屏覆盖层（面板 clipShape 会把
            // 261pt 高的环卡裁到只剩顶边）；竖屏仍挂平带里，一字不动。
            if model.ringPhase != .closed, !(screenHeight > 0 && screenWidth > screenHeight) {
                ringLayerInStrip
                    .opacity(model.overlayOpacity)
            }
            // 触摸层：盖住整条带，坐标与旧 DragGesture 的 .local 一致
            // （容器原点 = 带原点，卡片偏移由 flatOffsetX 换算，见 anchorNearestFlatCard）。
            StripTouchView(model: model) { idx in
                model.playTrack(at: idx, store: playback)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: model.flatHeight, alignment: .top)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: StripCenterKey.self,
                    value: proxy.frame(in: .named("liziHome"))
                )
            }
        )
        .onPreferenceChange(StripCenterKey.self) { rect in
            model.stripCenter = CGPoint(x: rect.midX, y: rect.midY)
            model.stripSize = rect.size
        }
    }

    /// 环层（r34，第 2/3/4 件）：平带里的环——卡片在原地变成 3D。
    /// 坐标是带内局部坐标（原点 = 带顶左缘）：卡中心 x = 带宽/2 +
    /// projectedX（透视投影后的位置，不是 R·sin），卡中心 y =
    /// ringCardCenterYLocal（盖面中心钉在平带盖面中心，见模型函数注释）。
    /// 变换按壳版 ring.js 一比一：rotateY(world) + perspective 卡高/P
    /// （P = 3.2R，壳版透视）→ 再绕 X 轴 -5° 后仰（perspective 0，
    /// 只取朝向、不叠透视；壳版相机 translateZ(-R) rotateX(-5°) 的
    /// 纵向下坠 r39-5 已删（tiltDrop，见模型函数注释；转动时卡片保持一条线），
    /// 这里只补卡面后仰——旧代码的
    /// 容器 rotateX(-5°) 是双算，还把 perspective 0.5 强透视带进来，
    /// r30 已删；卡面本身一直没有后仰，侧卡才看着像平面排布）。
    /// 压暗一层：整卡盖壳版公式平色（shadeOpacity，40° 时 3.8%）。
    /// r36-8：封面远缘渐变（0.42）已删，见 shadeOpacity 上方注释。
    /// 展开/收回中 depthScale/cameraScale 都跟有效半径走，
    /// 环从平面里长出来、收回平面里（r31 同款）。
    /// r39-5：第 5 件——点中的环卡整体上抬 1pt（r43-3；`selectedRingIndex`，
    /// 0.18s 动画；offset 放在 position 之后，沿屏纵向直上直下，不随卡面
    /// 旋转方向偏；其余卡片保持同一水平线）。
    private var ringLayerInStrip: some View {
        GeometryReader { geo in
            // r47-3：第 3 件——卡片循环抽到共用的 RingCardsLayer（见下），中心坐标仍是平带里的（带宽/2，ringCardCenterYLocal），
            // 渲染一字不动；横屏时这里不挂（见 flatStrip 的横屏守卫）。
            RingCardsLayer(model: model, centerX: geo.size.width / 2, centerY: model.ringCardCenterYLocal())
                .frame(width: geo.size.width, height: model.flatHeight)
        }
        .frame(height: model.flatHeight)
    }

    /// 入口提示行：只剩手势提示文字（「左右拖动展开 3D 环 · 拖动旋转」），
    /// 不再有按钮。
    /// r40：触发改回 r24（横向拖动开环），提示文字与图标同步改回横向；
    /// r39-5 的上滑开环 + 横向手滚跑马带作废。
    /// r28：「展开 3D 环」按钮已删（点按开环不在触发里）；
    /// 开环只剩平面带横向拖动（`stripTouchMoved` → `openRing`），
    /// 不加替代的提示按钮；颜色跟面板深场走（深场白字，浅场墨字）。
    private var entryHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            Text("左右拖动展开 3D 环 · 拖动旋转")
                .font(.liziBody(size: LiziTokens.size12))
        }
        .foregroundColor(model.panelIsDark ? .white.opacity(0.75) : LiziTokens.ink3)
        .opacity(1 - model.overlayOpacity) // r34：环开着时提示行跟平带一起淡出
    }
}

/// 环卡循环（r47-3：第 3 件——平带里 / 横屏覆盖层里共用的卡片循环，
/// 只差中心坐标：平带里中心 =（带宽/2，ringCardCenterYLocal）；
/// 横屏覆盖层里中心 =（stripCenter.x，ringCardCenterScreenY 夹取后）。
/// 透视、压暗、缩放、上抬、zIndex 与原来平带里的循环一字不动；
/// 位置由调用方给的 centerX/centerY 定（父容器坐标系）。
private struct RingCardsLayer: View {
    @ObservedObject var model: HomeCoverRingModel
    var centerX: CGFloat
    var centerY: CGFloat
    var body: some View {
        ZStack {
            ForEach(model.visibleSlots()) { slot in
                let card = model.itemCard(at: slot.trackIndex) // r43-2：第 2 件——通用卡，曲目路与旧 model.tracks[slot.trackIndex] 同内容
                let facing = model.facing(forWorld: slot.world)
                RingCardView(
                    card: card,
                    width: model.ringCard,
                    world: slot.world,
                    shadeFlat: model.shadeOpacity(facing: facing)
                )
                .scaleEffect(model.depthScale(forWorld: slot.world) * model.cameraScale())
                .rotation3DEffect(
                    .degrees(Double(slot.world)),
                    axis: (x: 0, y: 1, z: 0),
                    // r33，第 1 条：perspective 0 → 卡高/P（≈0.28）——正交旋转
                    // 的侧卡只是等比窄矩形、没有梯形，看着是平铺；按壳版 P=3.2R
                    // 再压一次近大远小，近缘比远缘宽约 12%，才是绕圆柱转圈。
                    perspective: model.ringCardPerspective
                )
                .rotation3DEffect(
                    .degrees(-5),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0
                )
                .opacity(model.facingOpacity(facing: facing))
                .position(
                    x: centerX + model.projectedX(forWorld: slot.world),
                    y: centerY
                )
                // r39-5：第 5 件——点中的环卡整体上抬 1pt（r43-3；0.18s 动画）；
                // offset 在 position 之后，沿屏纵向直上直下；其余卡片不动。
                .offset(y: model.selectedRingIndex == slot.trackIndex ? -HomeCoverRingModel.selectedLift : 0)
                .animation(.easeOut(duration: 0.18), value: model.selectedRingIndex == slot.trackIndex)
                .zIndex(Double(100 - abs(slot.world)))
                .accessibilityLabel(card.accessibilityLabel) // r43-2：第 2 件——曲目路「播放：标题」与旧值同值，通用路为标题本身
            }
        }
    }
}

/// 平面带里的一张卡：封面 + 歌名 + 歌手（r28：卡宽按档走 180/190/209；
/// 歌名 16pt 粗体、歌手 14pt，39.6s 新视频实测；颜色跟面板深场走——
/// 深场白字 + 灰字，浅场墨字；歌名/演唱者居中对齐卡片，见 r39-4）。
/// r43-2：第 2 件——卡面内容改走 `HomeRingCard`（coverURL/title/subtitle，
/// 曲目路由模型 `itemCard(at:)` 从 Track 合成：title = 歌名、subtitle = 歌手，
/// 渲染与旧 `Track.title`/`Track.artist` 同值；通用路直接取卡的标题/副信息）。
/// r39-4：第 4 件——卡下两行字（歌名粗体 + 演唱者）两种模式都画，
/// 只加这两个，不加专辑名；文字在卡片下面（封面下方、卡片外面），
/// 卡片里面只有封面，文字不叠在封面里面。歌名/演唱者取 `card.title` /
/// `card.subtitle`（曲目路 = `Track.title` / `Track.artist`，见 body）。
/// r37-1：coverOnly 时只放封面（歌名/歌手不画，带高 = 卡宽）——已作废
/// （r39-4：两种模式都画两行字，带高恒为卡宽 + 两行字高 + 1pt 上抬顶空（r43-3），
/// 见模型 `flatHeight`）；coverOnly 现在只剩封面未显示时的歌名占位开关。
/// r37-1 追加（用户 2026-11-22 00:39 显示逻辑）：coverOnly 且封面还没
/// 显示出来时，先盖歌名/歌手文字占位（白字盖在深色占位底上），用户能先滑、
/// 认出是哪首歌；封面一到占位消失、只剩封面。占位盖在封面框里，不占带高。
/// r39-4 注意：占位逻辑原样不动——封面加载中歌名会同时出现两次
/// （封面框里的占位 + 卡下的常驻行），封面一到占位消失，只剩卡下那行。
/// 点中的卡整体上抬 1pt（`isSelected`，封面 + 两行字一起；其余卡片
/// 保持同一水平线，见模型 `selectedLift` / 带顶 1pt 顶空；r43-3）。
///
/// 不是 Button：带子的触摸层（`StripTouchView`，盖在卡片上方）统一接管点按；
/// Button 和识别器的 tap 会双重触发。VoiceOver 激活走 `.accessibilityAction`。
private struct FlatRingCard: View {
    /// r43-2：第 2 件——卡面内容（调用方传 `HomeRingCard`；曲目路由模型
    /// `itemCard(at:)` 从 Track 合成，通用路直接传卡）。
    let card: HomeRingCard
    let width: CGFloat
    let isDark: Bool
    /// r37-1：只放封面（默认 false；歌单详情页 / 榜单详情页那路不传，
    /// 卡片仍带歌名/歌手）。
    /// r39-4：本开关不再藏卡下两行字（两种模式都画），只剩封面未显示时
    /// 的歌名占位开关（见 body 的占位分支与 `.task` 观测）。
    /// r37-9fix：必须是 `var` 不能是 `let`——`let` 带默认值时，默认值就算
    /// 一次初始化，成员初始化器不含它、显式 init 里再赋值会报
    /// immutable value may only be initialized once（run 44928276799）；
    /// `var` 带默认值才能进成员初始化器、调用方才能传 `coverOnly:`。
    var coverOnly: Bool = false
    /// r39-4：是不是点中的那张（调用方传 `model.selectedFlatIndex == i`；
    /// `var` 带默认值，同 coverOnly 的 r37-9fix 理由）。true 时整卡上抬 1pt（r43-3）。
    var isSelected: Bool = false
    let onTap: () -> Void

    /// r37-1 追加：这张卡的封面图是否已显示（`CoverImageLoader` 进程内
    /// 缓存观测；false = 占位底 + 歌名占位，true = 只剩封面）。
    /// 观测与 `CoverImageView`（`ProxyImageView`）走同一份加载器、同一
    /// 个在飞任务——不重复发请求；失败重试节拍（0.5s / 1.5s、最多 3 次）
    /// 照抄 `ProxyImageView`，免得图到了占位还赖着不走。
    @State private var coverLoaded = false

    /// r30：没封面（coverURL 为 nil）不摆白卡——深色默认封面（壳版
    /// `.mring__card.is-empty` 深色底 +「无封面」同款做法；原生占位图标
    /// 沿用 music.note，只把白底换成深色渐变）。URL 有但加载失败的白占位
    /// 在 CoverImageView.swift 里，本文件动不了。
    @ViewBuilder
    private var coverArt: some View {
        if card.coverURL == nil {
            DefaultCoverArt(iconSize: 64)
        } else {
            CoverImageView(url: card.coverURL, placeholderIconSize: 64)
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 7) { // r39-4：歌名/演唱者居中对齐卡片（定稿图，居中版）
            ZStack(alignment: .center) {
                coverArt
                    .frame(width: width, height: width)
                    .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
                // r37-1 追加：封面未显示时的歌名占位（只在 coverOnly 时出现；
                // 无封面 URL 的曲目永远无图可显，占位一直显示——那是唯一能
                // 认出歌的办法；有封面 URL 的图一到即消失，不变常驻标题）。
                if coverOnly && !coverLoaded {
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
            // r39-4：卡下两行字两种模式都画（只加歌名 + 演唱者，不加专辑名；
            // 歌名取 card.title、演唱者取 card.subtitle（曲目路 = Track.title /
            // Track.artist）；文字在封面下方、卡片外面，不叠在封面里面）。歌名粗体 16pt、演唱者 14pt，
            // 各一行、超长截断（lineLimit 1），居中对齐卡片。
            Text(card.title)
                .font(.liziBody(size: LiziTokens.size16, weight: .semibold))
                .foregroundColor(isDark ? .white : LiziTokens.ink)
                .lineLimit(1)
                .multilineTextAlignment(.center)
            Text(card.subtitle)
                .font(.liziBody(size: LiziTokens.size14))
                .foregroundColor(isDark ? .white.opacity(0.62) : LiziTokens.ink3)
                .lineLimit(1)
                .multilineTextAlignment(.center)
        }
        .frame(width: width, alignment: .center)
        // r43-3：点中的卡整体上抬 1pt（封面 + 两行字一起）；offset 只改
        // 渲染不改布局，其余卡片保持同一水平线。带顶留了 1pt 顶空
        // （flatStrip 的 .padding(.top, selectedLift)），上抬不被裁。
        .offset(y: isSelected ? -HomeCoverRingModel.selectedLift : 0)
        .animation(.easeOut(duration: 0.18), value: isSelected) // r39-4：上抬/落回短动画，不跳变
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.accessibilityLabel) // r43-2：第 2 件——曲目路「播放：标题」与旧值同值，通用路为标题本身
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .task(id: card.coverURL) {
            // r37-1 追加：观测封面是否已显示（见 coverLoaded 注释）；
            // coverOnly 为 false 时标题本来就画在卡下，不用观测。
            // url 一变任务重开，coverLoaded 先归 false（旧图不顶替新卡）。
            guard coverOnly else { return }
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
}

/// 没封面的默认封面（r30，FlatRingCard / RingCardView 共用；
/// r31：去掉 private，其余 5 个来源的跑马带卡片共用同一份，
/// 见 HomeView.swift `RailMarqueeCardView`）：
/// 深色渐变底 + music.note，绝不摆白卡。壳版 `.mring__card.is-empty`
/// 是深色底 +「无封面」字；原生占位图标沿用 music.note（CoverImageView
/// 同款图标），只把白底换成与深场面板/变暗后环面同色的深色渐变。
struct DefaultCoverArt: View {
    let iconSize: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.24), Color(white: 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

private struct FlatSetWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// r31：display link 回调代理。CADisplayLink 强持 target，模型直接当
/// target 会循环引用、deinit 永远不走（r26 Timer 漏表同款泄漏）；代理
/// 只弱持模型，模型释放时 deinit 停表，link 随模型一起释放。
/// r31-marquee：回调不再经 `Task { @MainActor in }` 跳主线程——
/// display link 已挂在 RunLoop.main 上，回调本身就在主线程；每帧一个
/// Task 会让步长在任务队列里扎堆（几帧的量一次走完、再空几帧），就是
/// 「一卡一卡」，dt 也要在回调当下读 link.timestamp，Task 里读到的
/// 是更新后的戳。r31 第一推文件头写的是「去掉 Task 跳线程」，代码里
/// 其实还留着，本轮才真去掉：代理直接调 tick（`MainActor.assumeIsolated`，
/// link 只加在 .main 上，回调只可能在主线程）。
/// 本文件只动这一处代理：flatDragging 的看门狗与全部出口（ended /
/// cancelled / failed / willMove / touchesCancelled）r26 已补齐，
/// ringPhase 收回竞态也被 `ringPhase == .open` 守卫封死（收回进行中
/// 没有任何调用能再推 closeGeneration），每日带没有能永久卡住的旗子，
/// 不动 tickFlat。
private final class FlatDisplayLinkProxy: NSObject {
    weak var model: HomeCoverRingModel?

    init(model: HomeCoverRingModel) {
        self.model = model
    }

    @objc func fired(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            self.model?.flatDisplayLinkFired(link)
        }
    }
}

/// r36-8：松手弹簧的 display link 回调代理（与 FlatDisplayLinkProxy
/// 同款：link 强持 target，模型直接当 target 会循环引用；代理只弱持模型，
/// 弹簧停稳时 link 随 stopRingSpring 一起释放；回调直接在主线程跑，
/// 不经 Task 跳线程——r31-marquee 同款教训：每帧一个 Task 会让步长
/// 在任务队列里扎堆，就是「一卡一卡」）。
private final class RingSpringDisplayLinkProxy: NSObject {
    weak var model: HomeCoverRingModel?

    init(model: HomeCoverRingModel) {
        self.model = model
    }

    @objc func fired(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            self.model?.ringSpringFired(link)
        }
    }
}

private struct StripCenterKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - 全屏环覆盖层（展开态）

/// 全屏环覆盖层（壳版 .mring：position:fixed inset:0）。
/// 由 HomeView 挂在根 VStack 的 `.overlay` 上（ScrollView 之外），
/// 内容：径向变暗 + 圆柱环（中心对准平面带原位置）+ 底部提示。
struct HomeRingOverlayView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @ObservedObject var model: HomeCoverRingModel

    var body: some View {
        GeometryReader { geo in
            // r31：环锚点（变暗中心与环中心同点）——横向面板中心、
            // 纵向带子中心，见 ringCenterY / panelRect；面板动，锚点就动。
            // 旧的固定屏中心 (0.5, 0.48) 只在尺寸量不到时作回落。
            let ringCy = model.ringCenterY(screenHeight: geo.size.height) // r51（D5）：topEdge 实参随参数删除
            let ringCx = model.panelRect(screenWidth: geo.size.width) // r51（D5）：halfWidth 已删，panelRect 现直接返回中心 x
            ZStack {
                // 全屏径向变暗（r31：中心跟环走，不再是固定 50% / 48%；
                // 三档 0.36/0.58/0.78 与半径不动）。
                // r36-8，第 1 条：压暗层在环卡带上开洞（见 scrimHoleMask）——
                // 壳版 `.mring` 的压暗是背景、卡片是它的孩子、画在压暗上面，
                // 卡片根本不被压；原生之前压暗层盖在环卡上面（卡在页里、
                // 压暗层在覆盖层里），中心卡先被 ×0.64，侧卡再叠 0.42 远缘
                // 渐变，同曲《回到你身边》壳版卡面 135、原生 45。开洞后卡片
                // 亮度与壳版同款（只剩 3.8% flat shade），洞外页面照常压暗。
                radialScrim(size: geo.size, centerX: ringCx, centerY: ringCy)
                    .mask(scrimHoleMask(containerHeight: geo.size.height))
                // r47-3：第 3 件——横屏时环卡挂在这里（全屏覆盖层，面板
                // clipShape 裁不到；竖屏环卡仍在平带里，这里不挂）。
                // 中心 x = 带子中心（stripCenter.x，量不到时回落屏中心），
                // 中心 y = ringCardCenterScreenY（横屏夹到屏内，与命中测试
                // 同公式）。压暗层在下、卡片在上（开洞只让卡片亮，顺序不能反）；
                // 触摸层仍在最上层。透明度跟外层 ZStack 的 overlayOpacity。
                if geo.size.width > geo.size.height {
                    RingCardsLayer(
                        model: model,
                        centerX: model.stripCenter.x > 0 ? model.stripCenter.x : geo.size.width / 2,
                        centerY: model.ringCardCenterScreenY(screenHeight: geo.size.height)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // r36-8，删：拖动时顶部再暗一档（0.14 黑、上 55% 高、
                // isRingDragging 驱动）已删——壳版 ring.js 里没有拖动加暗
                // 这一层（`.mring.is-drag` 只换光标）；壳版视频里拖动中
                // Hero 亮度与开环静止时一样（约 42–44），没有再暗一档。
                // 它还盖在环卡带的上半截，跟着一起拖累卡面亮度。
                // r34：第 4 件——圆柱环已经搬进平带容器（flatStrip 里的
                // ringLayerInStrip），覆盖层不再画卡；这里只剩变暗 +
                // 底部提示 + 触摸层。
                // r47-3：第 3 件——横屏例外：环卡改挂覆盖层（见上），竖屏
                // 仍走平带里的环。
                // 底部提示（视频原字；位置约 94% 屏高、居中）。
                // r33，第 4 条：原来是 VStack + Spacer + padding(.bottom,
                // max(16, safeArea+10))——safeAreaInsets 在 ignoresSafeArea
                // 的 GeometryReader 里读到 0 时只垫 16pt，提示会沉到约 97%
                // 屏高、贴着 Home Indicator，甚至与底下的本地音乐文件夹
                // 副标题行叠在一起（视频 f_001–f_030 的提示行就叠在那行上，
                // 30 帧里 94% 高度处一个亮像素都没有）。改成按屏高 94%
                // 定死位置，不依赖 safeArea 读数；横屏竖屏同一套。
                Text("拖动旋转 · 点击播放 · 松手收回")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.74))
                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 1)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.94)
                // r24：触摸层（RingTouchView，UIKit，文件尾）盖在最上层——
                // 整块覆盖层的触摸都归它：拖动转环、点卡播歌、点空白收回、
                // 下滑退出（ring.js onOverlayDown + window pointer 监听同款）。
                // 旧的 SwiftUI DragGesture + onTapGesture 已删（第 4 件根因：
                // 两者叠在同一视图上，真机上拖动到不了模型）。
                // r26-3D：命中测试用 ringCardCenterScreenY（与渲染同公式），
                // 点按盒与眼睛看到的卡片位置一致。r51（D5）：hitTestRingCard
                // 的 topEdge 参数已删；RingTouchView 自带的 topEdge 接口不在
                // D5 范围内，保留，仍按横竖屏传 64/95。
                RingTouchView(model: model, topEdge: geo.size.width > geo.size.height ? 64 : 95) { idx in
                    model.tapRingCard(trackIndex: idx, store: playback)
                } onTapBlank: {
                    model.closeRing(quick: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .opacity(model.overlayOpacity)
        }
        .ignoresSafeArea()
        // r51：第 1 件——弹簧吸附阶段的带子同步已拆（r33 联动的 onChange(of: angle)
        // 同步作废，改回套壳语义）：angle 只转环，不再写 flatOffsetX；带子停在
        // 旧位置，收环 220ms 后接着滚。
    }

    /// 压暗层的开洞 mask（r36-8，第 1 条）：环卡带那一条上下 16pt 羽化、
    /// 中间全透明（压暗层在那里不盖卡片），洞外全黑（压暗照常）。
    /// 洞的位置跟活的带子走（stripCenter/stripSize 是偏好上报的实时值，
    /// 与命中测试、变暗中心同一份锚点）：纵向以环卡中心为准
    /// （stripCenter.y − 3，见 ringCenterY 的推导：卡中心 = stripCenter.y，
    /// 再 −3pt 是旧的量取余量），高取
    /// ringCardHeight（卡片纵向全高）；横向整宽（侧卡溢出到屏边，
    /// 洞必须盖到屏边）。带子还没量到（stripSize = 0）时不开洞——
    /// 整层压暗（旧行为），量到后自动跟过去。
    /// 洞里露出来的是没压暗的面板底色（卡缝处）：原生面板是专辑取色、
    /// 偏深（实测约 40），与壳版压暗后的面板（约 50）接近；浅色专辑
    /// 时卡缝会比壳版亮一档，见交回残留。
    private func scrimHoleMask(containerHeight: CGFloat) -> LinearGradient {
        let h = max(1, containerHeight)
        let feather: CGFloat = 16
        guard model.stripSize.height > 0 else {
            return LinearGradient(colors: [.black, .black], startPoint: .top, endPoint: .bottom)
        }
        // r47-3：第 3 件——横屏时洞跟夹取后的环中心走（卡片挂在覆盖层里、
        // 洞还按带子开会把卡片压暗）；竖屏原值不动。
        let cy = model.isLandscapeScreen
            ? model.ringCardCenterScreenY(screenHeight: containerHeight) - 3
            : model.stripCenter.y - 3
        let half = model.ringCardHeight / 2
        let top0 = max(0, min(1, (cy - half - feather) / h))
        let top1 = max(0, min(1, (cy - half) / h))
        let bot0 = max(0, min(1, (cy + half) / h))
        let bot1 = max(0, min(1, (cy + half + feather) / h))
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: top0),
                .init(color: .clear, location: top1),
                .init(color: .clear, location: bot0),
                .init(color: .black, location: bot1),
                .init(color: .black, location: 1),
            ]),
            startPoint: .top, endPoint: .bottom
        )
    }

    private func radialScrim(size: CGSize, centerX: CGFloat, centerY: CGFloat) -> some View {
        let dark = Color(red: 9 / 255, green: 10 / 255, blue: 16 / 255)
        let darker = Color(red: 5 / 255, green: 6 / 255, blue: 10 / 255)
        // r31：变暗中心 = 环中心（调用方按 stripCenter 算出）；尺寸量不到时
        // 回落屏中心 (0.5, 0.48)。三档与半径见下，不动。
        let ux = size.width > 0 ? centerX / size.width : 0.5
        let uy = size.height > 0 ? centerY / size.height : 0.48
        // r28：0.36/0.58/0.78——39.6s 新视频整页实测 0.42 倍（f_001 均值
        // 121.3 → f_050 51.4）；旧 0.40/0.70/0.88 按面积均值算约 0.26 倍，
        // 太暗（Hero 区实测 0.40 倍、顶栏 0.31 倍，新值约 0.49/0.33，见交回）。
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: dark.opacity(0.36), location: 0),
                .init(color: dark.opacity(0.58), location: 0.56),
                .init(color: darker.opacity(0.78), location: 1),
            ]),
            center: UnitPoint(x: ux, y: uy),
            startRadius: 0,
            endRadius: max(size.width, size.height) * 0.62
        )
    }

}

/// 环里的一张卡：封面 + 歌名 + 歌手（壳版 .mring__card：封面下只写歌名；
/// 视频里歌名下还有歌手，加一行）。
/// 压暗一层（r36-8，第 1 条）：只剩整卡壳版公式平色（shadeFlat，
/// 0.55·((1-facing)/2)^1.25，40° 时 3.8%）——壳版 `.mring__shade`
/// 是 inset: 0 的整卡覆盖（含歌名行），平色层盖在整卡上；r33 的封面
/// 远缘渐变（shadeFar，40° 时 0.42）已删，见模型处注释。
///
/// r22c：文字左对齐——8 张截图里每张环卡的歌名/歌手都从卡片左缘起
/// （r21 的居中与截图不符；壳版 `.mring__name` 也是默认左对齐）。
private struct RingCardView: View {
    /// r43-2：第 2 件——卡面内容（调用方传 `HomeRingCard`；曲目路由模型
    /// `itemCard(at:)` 从 Track 合成，通用路直接传卡；渲染只读这三字段）。
    let card: HomeRingCard
    let width: CGFloat
    /// 该槽的世界角（度）：正 = 右侧卡，负 = 左侧卡。
    let world: CGFloat
    /// 整卡平色黑度（0…1，模型 `shadeOpacity` 壳版公式算出；中心卡为 0）。
    let shadeFlat: Double

    /// r30：没封面（coverURL 为 nil）不摆白卡——深色默认封面（见 FlatRingCard
    /// coverArt 注释）。r33，第 2 条：URL 有但加载失败/还没到时也不摆白卡——
    /// CoverImageView 走深色占位（`darkPlaceholder`），环里绝不留浅灰音符占位。
    @ViewBuilder
    private var coverArt: some View {
        if card.coverURL == nil {
            DefaultCoverArt(iconSize: 48)
        } else {
            CoverImageView(url: card.coverURL, placeholderIconSize: 48, darkPlaceholder: true)
        }
    }

    /// r36-8，删：`shadeGradient`（r33，第 1 条：沿卡面横向渐变，
    /// 近缘 0 → 远缘 shadeFar，40° 时 0.42）随 `shadeFarEdge` 一起删——
    /// 壳版 shade 只有 flat 公式，侧卡不另加远缘渐变。
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            coverArt
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.8), radius: 26, x: 0, y: 12)
            Text(card.title)
                .font(.liziBody(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 1)
            Text(card.subtitle)
                .font(.liziBody(size: 13))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 1)
        }
        .frame(width: width, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(shadeFlat))
                .allowsHitTesting(false)
        )
    }
}

// MARK: - 平面带触摸层（r22c，UIKit）

/// 平面带的触摸层：一个透明 UIView，盖在跑马带卡片上方，接管带子上的
/// 全部触摸（点按 + 横向拖动开环 + 开环后继续转环）。
///
/// 为什么不用 SwiftUI DragGesture（r21 的教训）：带子在竖向 ScrollView 里，
/// `.simultaneousGesture(DragGesture)` 在真机上拦不住 ScrollView 的竖滑——
/// 竖向拖动的手势会被页面滚动抢走，`openRing` 根本到不了，环打不开。
/// 壳版的等价物是 `.mstrip { touch-action: none; }`（见 public/m/m.css），
/// 即带子拥有全部触摸；这里用 UIKit 识别器复刻同一条语义：
/// - `shouldBeRequiredToFailBy`：ScrollView 的 pan 必须等我们的 pan 先失败
///   才开始滚页面——横向拖动开环由我们接管（r40：改回 r24；r39-5 的
///   上滑开环 + 横向手滚跑马带作废），页面滚不动；
/// - 方向判定后是竖向（上/下都一样）：我们的 pan 自毁（`isEnabled` 开关一次），
///   ScrollView 接管，页面接着滚（r24「竖向 = 交还页面」同款；
///   横向拖动开环见模型 `stripTouchMoved`）；
/// - 同一根手指从按下一路管到开环、转环、松手（壳版 window pointer 监听
///   同款），不依赖「覆盖层半路出现后新 DragGesture 能接到旧触摸」。
///
/// 坐标：识别器报的是本视图本地坐标，与旧 DragGesture 的 `.local` 一致
/// （容器原点 = 带原点；卡片偏移由 `flatOffsetX` 换算，见 `anchorNearestFlatCard`）。
struct StripTouchView: UIViewRepresentable {
    @ObservedObject var model: HomeCoverRingModel
    /// 点按某张卡（下标由识别器用 `anchorNearestFlatCard` 算出）。
    var onTapCard: (Int) -> Void

    @MainActor
    func makeUIView(context: Context) -> StripTouchUIView {
        let view = StripTouchUIView()
        view.model = model
        view.onTapCard = onTapCard
        return view
    }

    @MainActor
    func updateUIView(_ uiView: StripTouchUIView, context: Context) {
        uiView.model = model
        uiView.onTapCard = onTapCard
    }
}

/// 平面带触摸的 UIKit 宿主视图（主线程；手势回调都在主线程进模型）。
@MainActor
final class StripTouchUIView: UIView, UIGestureRecognizerDelegate {
    weak var model: HomeCoverRingModel?
    var onTapCard: ((Int) -> Void)?

    private lazy var pan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.delegate = self
        // 点按只在 pan 没认出来时才算（带一点位移的轻触按拖动走，不双重触发）。
        recognizer.require(toFail: pan)
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 识别器委托

    /// ScrollView 的 pan 必须等我们的 pan 先失败：横向由我们接管
    /// （横向拖动开环，r40 改回 r24），页面滚不动；只有我们判定为
    /// 竖向（上/下）而自毁后，页面才接着滚。
    /// （壳版 `.mstrip { touch-action: none; }` 的 UIKit 等价物。）
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === pan,
              otherGestureRecognizer is UIPanGestureRecognizer,
              otherGestureRecognizer.view is UIScrollView
        else { return false }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    // MARK: 手势回调

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let model else { return }
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            model.stripTouchBegan(x: location.x, y: location.y)
        case .changed:
            if model.stripTouchMoved(x: location.x, y: location.y) == .failGesture {
                // 竖向占优且向下：自毁、把手势交还 ScrollView（壳版 detachPress 同款）。
                model.stripTouchEnded()
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        case .ended, .cancelled:
            model.stripTouchEnded()
        case .failed:
            // r26：识别器认出手势失败（began 之后极少见，但一旦发生，
            // 之前 began 置起的 flatDragging 必须清掉，否则跑马带永远停；
            // began 没走过时 flatDragging 是 false，不调 stripTouchEnded，
            // 免得白白把 dwell 推后 1s）。
            if model.flatDragging {
                model.stripTouchEnded()
            }
        default:
            break
        }
    }

    /// r26：系统取消触摸（来电、锁屏、控制中心等）：识别器一般会跟着走
    /// .cancelled，但万一没走到，原始取消也必须把 flatDragging 清掉，
    /// 否则跑马带永远停。
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if model?.flatDragging == true {
            model?.stripTouchEnded()
        }
    }

    /// r26：触摸层被拆掉（数据重载切分支、旋转换竖横分支）时，正在进行的
    /// 手势随视图一起死，ended 再也不会来；移除瞬间把 flatDragging 清掉，
    /// 否则新挂上的带子继承一面永远卡住的旗子、跑马带永远停。
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil, model?.flatDragging == true {
            model?.stripTouchEnded()
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let model, recognizer.state == .ended else { return }
        let location = recognizer.location(in: self)
        // r33，第 4/11 件：点按必须落在卡上才播（见 isTapOnFlatCard）——
        // 卡缝/空白处的点按直接丢弃，不按最近卡播歌。
        guard model.isTapOnFlatCard(x: location.x) else { return }
        onTapCard?(model.anchorNearestFlatCard(x: location.x))
    }
}

// MARK: - 环覆盖层触摸层（r24，第 3/4 件，新写）

/// 全屏环覆盖层的触摸层：一个透明 UIView，盖在环卡与提示文字上方，
/// 接管环开着时的全部触摸（ring.js 里覆盖层 `.mring` 的 pointerdown +
/// window pointermove/pointerup 同款——同一根手指从按下一路管到
/// 松手，不依赖 SwiftUI 手势半路接力）。
///
/// 为什么不用 SwiftUI DragGesture + onTapGesture（r22c 旧做法，第 4 件根因）：
/// 两者挂在同一视图上，真机上拖动到不了模型——环开着、手指拖环面，
/// 角一直停在 0，只有锚点卡停在中间（「3D 封面只会在中间」）。
/// 这里只挂一对 UIKit 识别器（pan + tap，tap require(toFail: pan)，
/// 与 StripTouchView 同款）：r23 长按死锁的教训——不要再叠
/// highPriorityGesture / sequenced / 长按识别器抢同一根触摸。
///
/// 坐标：本视图铺满整块覆盖层，覆盖层又铺满整屏；本地坐标原点与
/// "liziHome" 坐标系同在屏左上角，所以本地 (x, y) 可以直接当
/// liziHome 坐标用（ringDragStart / hitTestRingCard 的入参）。
struct RingTouchView: UIViewRepresentable {
    @ObservedObject var model: HomeCoverRingModel
    /// 顶栏底边（r26-3D：命中测试与环层同公式 ringCardCenterScreenY；
    /// HomeRingOverlayView 按横竖屏传 64/95，与命中测试同值）。
    var topEdge: CGFloat = 95
    var onTapCard: (Int) -> Void
    var onTapBlank: () -> Void

    @MainActor
    func makeUIView(context: Context) -> RingTouchUIView {
        let view = RingTouchUIView()
        view.model = model
        view.topEdge = topEdge
        view.onTapCard = onTapCard
        view.onTapBlank = onTapBlank
        return view
    }

    @MainActor
    func updateUIView(_ uiView: RingTouchUIView, context: Context) {
        uiView.model = model
        uiView.topEdge = topEdge
        uiView.onTapCard = onTapCard
        uiView.onTapBlank = onTapBlank
    }
}

/// 环覆盖层的 UIKit 宿主视图（主线程；手势回调都在主线程进模型）。
@MainActor
final class RingTouchUIView: UIView, UIGestureRecognizerDelegate {
    weak var model: HomeCoverRingModel?
    var topEdge: CGFloat = 95
    var onTapCard: ((Int) -> Void)?
    var onTapBlank: (() -> Void)?

    /// 本次触摸起点（touchesBegan 记，pan 的 .began 要等到第一下移动才回调，
    /// 等不及——起点丢了，5px 死区与下滑退出都没法算）。
    private var startX: CGFloat = 0
    private var startY: CGFloat = 0
    /// 5px 死区过了没有（ring.js RING_THRESHOLD=5：没过 = 还不算拖动）。
    private var dragStarted = false

    private lazy var pan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        return recognizer
    }()

    private lazy var tap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        recognizer.delegate = self
        // 点按只在 pan 没认出来时才算（带一点位移的轻触按拖动走，不双重触发；
        // 与 StripTouchView 同款）。
        recognizer.require(toFail: pan)
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }

    /// 手指刚落下（pan 的 .began 要等到第一下移动才回调，等不及）：
    /// 记起点 + 取消待执行的松手收回（ring.js onOverlayDown → beginPress →
    /// clearHold 同款，不然手指按着不动 1s，环会在手指底下收掉）。
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)
        startX = location.x
        startY = location.y
        dragStarted = false
        model?.ringTouchBegan()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let model else { return }
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .changed:
            guard model.ringPhase == .open else { return }
            let dx = location.x - startX
            let dy = location.y - startY
            if !dragStarted {
                // 下滑退出（ring.js onPressMove ring 分支：明显向下滑 =
                // 退出环；只在拖动还没起步时判，拖起来以后竖向分量忽略）。
                if dy > HomeCoverRingModel.swipeDownExit, abs(dy) > abs(dx) * 1.25 {
                    model.closeRing()
                    recognizer.isEnabled = false
                    recognizer.isEnabled = true
                    return
                }
                if hypot(dx, dy) < HomeCoverRingModel.ringThreshold { return }
                dragStarted = true
                model.ringDragStart(x: location.x, y: location.y)
            }
            model.ringDragMoved(toX: location.x)
        case .ended, .cancelled:
            if dragStarted {
                dragStarted = false
                // r48-4：第 4 件——带一点晃动的点按（>5px 死区、<20pt 晃动）：
                // pan 认出来了、tap 的 require(toFail: pan) 不触发，旧代码
                // 只走 ringDragEnded、不试点卡——右滑后手指再落下来点卡，
                // 轻微一晃整下点按就被拖动手势吞掉（点按事件被拖动手势吞了，
                // 与 r46-7 修的「没拖起来」是同一类丢点按、不同分支：那
                // 处只覆盖 dragStarted == false，这里覆盖拖起来了但只是
                // 一晃）。晃动小且环基本没转（<1/4 槽）时按松手落点试一次
                // 点卡（与 r46-7 没拖起来分支同款）；真拖动（位移大/转过
                // 槽）时不试，拖动就是拖动。角用 ringDragEnded 后的当前角
                // （弹簧还没跑起来，读到的是松手那一刻的角）。
                let wobble = hypot(location.x - startX, location.y - startY) < 20
                let angleBefore = model.ringStartAngle
                model.ringDragEnded()
                if wobble, abs(model.angle - angleBefore) < model.ringStep * 0.25,
                   (model.ringPhase == .open || model.ringPhase == .closing),
                   let idx = model.hitTestRingCard(at: location, screenWidth: bounds.width, screenHeight: bounds.height) { // r51（D5）：topEdge 实参随参数删除
                    onTapCard?(idx)
                }
            } else if (model.ringPhase == .open || model.ringPhase == .closing),
                      let idx = model.hitTestRingCard(at: CGPoint(x: startX, y: startY), screenWidth: bounds.width, screenHeight: bounds.height) { // r51（D5）：topEdge 实参随参数删除
                // r46-7：第 7 件——晃一下就抬手（pan 认出来了、tap 没触发、
                // 模型又没判成拖动）：按落点（startX/startY，用户的本意）
                // 试一次点卡——落点在卡上就播歌 + 收环（与点按同款）；
                // 落点不在卡上才走旧路（补 1s 收回定时器，环不永远开着）。
                // 命中盒与渲染同公式（stripCenter 活量 + projectedX），
                // 转环后点任意可见卡都落得到盒里。
                onTapCard?(idx)
            } else {
                // r33，第 3 条：没拖起来（<5px 晃一下就抬手）也要补一个
                // 松手收回——touchesBegan 已经取消了待执行的收回定时器，
                // 这次触摸既没走 ringDragEnded、又没走点按（pan 认出来了，
                // tap 不触发），不补定时器环就永远开着。
                model.ringTouchEnded()
            }
        case .failed:
            // r37-9：识别器中途失败（被系统手势抢走等）——StripTouchView
            // 的 .failed 同款出口，Ring 这边之前没有：失败后 .ended 再也
            // 不来，dragStarted / ringDragging 双双卡住，换手后新拖动
            // 接不上。没拖起来时什么都不做（手指还按着，环保持开着；
            // 抬手后 tap 会走点卡/点空白那条路）。
            if dragStarted {
                dragStarted = false
                model.ringDragEnded()
            }
        default:
            break
        }
    }

    /// 系统取消触摸（r33，第 3 条；来电、锁屏、控制中心等）：
    /// touchesBegan 已经取消了待执行的收回定时器，取消后 pan 不一定
    /// 再走 .cancelled——这里按同一套收尾：拖起来了走 ringDragEnded，
    /// 没拖起来走 ringTouchEnded（重排 1s 收回）。StripTouchView 同款
    /// 兜底（见该文件 touchesCancelled），覆盖层之前没有。
    /// 与 pan .cancelled 双重触发时：第二次 ringDragEnded 会再排一个 1s
    /// 定时器（代号 +1 作废前一个，只剩后一个），结果不变，安全。
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        if dragStarted {
            dragStarted = false
            model?.ringDragEnded()
        } else {
            model?.ringTouchEnded()
        }
    }

    /// r37-9：触摸层被拆掉时（收回完成 overlay 卸载、数据重载关环等），
    /// 正在进行的手势随视图一起死，.ended 再也不会来；StripTouchView
    /// 同款兜底，Ring 这边之前没有——移除瞬间把拖动会话清掉，否则新
    /// 挂上的环继承一面卡住的 ringDragging，下一次拖动接不上。
    /// 与 touchesCancelled 双重触发时：第二次 ringDragEnded 只会按同一份
    /// 旧采样再排一个 1s 收回（代号 +1 作废前一个），结果不变，安全。
    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        if newSuperview == nil, dragStarted {
            dragStarted = false
            model?.ringDragEnded()
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let model, recognizer.state == .ended else { return }
        // r46-7：第 7 件——.closing 也接受：松手 1s 后环开始 430ms 收回淡出，
        // 淡出期内卡片还看得见，旧守卫（只认 .open）把这段点按整个吞掉——
        // 转完环、看一眼再点，环已在收，点按无反应。tapRingCard 里的
        // closeRing 在 .closing 时是 no-op（见 closeRing 守卫），收回继续走、
        // 不会闪回；点中的卡照常播歌。
        guard model.ringPhase == .open || model.ringPhase == .closing else { return }
        let location = recognizer.location(in: self)
        if let idx = model.hitTestRingCard(at: location, screenWidth: bounds.width, screenHeight: bounds.height) { // r51（D5）：topEdge 实参随参数删除
            onTapCard?(idx)
        } else {
            onTapBlank?()
        }
    }
}
