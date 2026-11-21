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
/// 开环：上滑（|dy|>|dx|×1.25 且 dy<0，超 10px），横向拖动只滚带；
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
/// 联动（用户 10:11/10:12 第 1 条，环跟着下面那排卡片走）：环与带子共用
/// 同一个当前索引（`ringCenterTrackIndex`）。拖动环时带子实时跟过去
/// （ringDragMoved 里 `syncFlatOffsetToRingCenter`：带子中心对准环当前那首；
/// 弹簧吸附阶段由覆盖层 onChange(of: angle) 跟过去）；环收回后带子从这首
/// 继续自动滚，开关环不丢位置。环的位置本来就从带子派生（ringCenterY =
/// stripCenter.y、横向 panel.centerX，r31；实测环中心 = 带子中心 + tiltDrop
/// 约 20pt，对得上），本轮不动锚点。开环时不同步带子（0.26s 淡出里跳变会闪），
/// 锚点仍是在播曲目/手指卡（用户 22:33 定稿）。冲突说明：带子自动滚时环
/// 跟着转——环开着时带子是冻住的（tickFlat 的 ringPhase == .closed 守卫），
/// 想让环边开边跟带子转就得让环自己转起来，与「环本身不自动转」的既有规矩
/// 冲突，按用户 10:11 的冲突条款以既有规矩为准；且 24px/s 折到环上只有
/// 约 4.7°/秒，1 秒保持期内只漂约 5°，放开也看不见——联动落在开环锚点 +
/// 拖动跟随 + 收回交接三处，连续跟随留给以后一轮（angle 改从 flatOffsetX
/// 派生是大重构，不在本轮做）。
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

// MARK: - 状态机

/// 首页环的状态机：平面跑马带 + 全屏圆环共用一份。
///
/// 手势入口有两处（同一根手指可以不断开）：平面带上的上滑（展开后继续拖
/// 就是转环，壳版 enterRing 同款）与覆盖层上的直接拖动；两处都调
/// `ringDragStart` / `ringDragMoved` / `ringDragEnded`。
@MainActor
final class HomeCoverRingModel: ObservableObject {
    enum RingPhase { case closed, open, closing }

    // MARK: 输入（HomeCoverRingView 从调用方同步进来）

    @Published var dailyTracks: [Track] = []
    /// 在播曲目的身份键（`platform:id`；r26-3D 开环锚点用，不驱动渲染，
    /// 故不用 @Published；调用方经 syncInputs 同步 playback.currentTrack）。
    var playingKey: String?
    @Published var isLoadingDaily = false
    @Published var dailyEmptyReason: String?
    @Published var marqueeSpeed: CGFloat = 24
    @Published var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 面板是否为深场（调用方按专辑取色 field 同步，见 HomeView AlbumTone）：
    /// 深场时平面卡歌名/歌手/提示用白字，浅场用墨字。默认 true
    /// （默认 tone #5b5bd6/#b04f8c/#2f6f8f 是深场，见 AlbumTone.default）。
    @Published var panelIsDark = true

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
    /// 正在拖动环（手指按下且在转环，或开环手指未抬起）：覆盖层顶部再暗一档。
    @Published var isRingDragging = false
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

    /// 环当前中心曲目在列表里的下标（r33 联动用：环与带子共用的当前索引）。
    var ringCenterTrackIndex: Int {
        guard !tracks.isEmpty else { return 0 }
        return mod(anchorIndex + ringCenterSlot, tracks.count)
    }

    // MARK: 常量（壳版 ring.js 原值，见文件头）

    static let dragThreshold: CGFloat = 10       // 平面带上超 10px 才判方向
    static let ringThreshold: CGFloat = 5        // 环里超 5px 才算拖动
    static let holdMs: Double = 1000            // 松手后环保持多久再收
    static let enterMs: Double = 520             // 环展开
    static let closeMs: Double = 430             // 自动收回
    static let quickCloseMs: Double = 220        // 点空白快收
    static let tau: CGFloat = 1.08               // 惯性时间常数
    static let springStiffness: CGFloat = 118    // 弹簧
    static let maxVelocity: CGFloat = 1400       // 角速度限幅（度/秒）
    static let sampleMs: Double = 0.110          // 角速度采样窗
    static let dragGain: CGFloat = 1.45          // 拖动增益
    static let resumeMs: Double = 1200           // 平面带松手后多久恢复自动走
    static let initialDwell: Double = 2.5        // 初画/回卷后停多久再走
    static let dragResumeDwell: Double = 1.2     // 平面带拖动松手后停多久再走
    // r28：与上面 resumeMs=1200 对上（39.6s 视频规格：松手 1200ms 后恢复；
    // 之前 dragResumeDwell=1.0，resumeMs 白定义了没人用）。
    static let closeResumeMs: Double = 220       // 收回后多久恢复自动走
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

    /// 在播曲目在当前列表里的下标（开环锚点用；不在列表里回 nil，
    /// 开环回落手指卡/正中卡）。
    var playingIndex: Int? {
        guard let key = playingKey else { return nil }
        return tracks.firstIndex { $0.platform + ":" + $0.id == key }
    }

    /// 调用方数据同步进来；曲目 id 集合变了（切平台/重拉）才重置
    /// （壳版 setItems 同款语义）。
    func syncInputs(daily: [Track], isLoading: Bool,
                    emptyReason: String?, playing: Track?,
                    speed: CGFloat,
                    tier: PlayerTokens.PlayerSizeTier,
                    panelIsDark: Bool = true) {
        startFlatTimer()
        let oldIDs = tracks.map(\.id)
        dailyTracks = daily
        playingKey = playing.map { $0.platform + ":" + $0.id }
        isLoadingDaily = isLoading
        dailyEmptyReason = emptyReason
        marqueeSpeed = speed
        self.tier = tier
        self.panelIsDark = panelIsDark
        if tracks.map(\.id) != oldIDs {
            if ringPhase != .closed { closeRing() }
            flatOffsetX = 0
            flatDwellUntil = Date().addingTimeInterval(Self.initialDwell)
            flatDwellReason = "ids-changed"
        }
        // r33-marquee：带宽兜底（与 rail 的 ensureSetWidth 同款）：
        // flatSetWidth 正常由 FlatSetWidthKey 偏好上报；偏好没到时 tickFlat
        // 的 setWidth > 0 守卫永远拦住、带子永远停。只在 flatSetWidth 小于
        // 一份宽度且有曲目时按卡数补，与偏好公式同值（n×(卡宽+间距)）。
        // r34：`== 0` 改成 `< 一份宽度`——偏好在布局完成前会先报 0，
        // 偏好处理把它写成 0+16=16，旧的 `== 0` 再也修不回来（16 ≠ 0），
        // 带子只能在 16pt 里打转、看着就是冻住。小于一份宽度只可能是
        // 布局前的 0/残值，直接按卡数补满。
        if flatSetWidth < CGFloat(tracks.count) * (flatCard + flatGap), !tracks.isEmpty {
            flatSetWidth = CGFloat(tracks.count) * (flatCard + flatGap)
        }
    }

    // MARK: 尺寸（视频实测，见文件头分档表）

    /// 平面卡宽：compact 180 / standard 190 / large 209（≈0.486vw，
    /// 39.6s 新视频卡 350px/720px）。
    var flatCard: CGFloat {
        switch tier {
        case .compact: return 180
        case .standard: return 190
        case .large: return 209
        }
    }

    var flatGap: CGFloat { 16 }

    var flatPitch: CGFloat { flatCard + flatGap }

    /// 平面带高：卡 + 间距 7 + 16pt 歌名行 + 间距 7 + 14pt 歌手行
    /// （r28：字号 14/13→16/14，行高跟着涨 3pt，旧 +49 会裁掉歌手行）。
    var flatHeight: CGFloat { flatCard + 52 }

    /// 环卡宽：compact 141 / standard 149 / large 164（≈0.382vw，
    /// 39.6s 新视频中心卡 275px/720px）。
    var ringCard: CGFloat {
        switch tier {
        case .compact: return 141
        case .standard: return 149
        case .large: return 164
        }
    }

    /// 相邻槽位夹角 40°（壳版公式 step = min(360/n, 2·asin(pitch/(2R)))，
    /// n = min(曲数, cap)，cap = round(2πR/pitch) = 9：曲数 ≥ 9 时
    /// 360/9 = 40°，第二项 2·asin(pitch/(2R)) = 40.0°（弦长公式反推，
    /// pitch/(2R) = sin20°），min 取 40°；曲数 < 9 时 360/n > 40°，
    /// 第二项仍约 40.0°——三档、任意曲数下公式值都在 40° 上，
    /// 写死 40 与公式值一致，见驱动 §R3 镜像。r35 前旧值也是 40°，
    /// 但旧 pitch=卡宽、R≈218pt 时它是「视频实测」的数；现在
    /// pitch/R 换回壳版，40° 是公式算出来的）。
    var ringStep: CGFloat { 40 }

    /// 槽距 = 卡宽×1.14（r35：换回壳版 ring.js openRing 原式
    /// pitch = cardW * 1.14；r31 的「视频实测 pitch≈卡宽」已被用户
    /// 2026-11-21 真机报告推翻——环开着拖动旋转时相邻卡几乎相贴，
    /// 旧 pitch 下静止间隙只有约 2.9pt、拖动中途重叠约 11pt；
    /// 新 pitch 下静止间隙约 21pt、拖动中途也不相贴，见驱动 §R4–§R5
    /// 镜像。只改 pitch 这一处，R / P / perPixel 由它派生）。
    var ringPitch: CGFloat { ringCard * 1.14 }

    /// 环容量 cap = clamp(round(2πR/pitch), 7, 64)（壳版 openRing 原式；
    /// 三档都是 round(9.18) = 9）。n = min(曲数, cap)，见 ringStep。
    var ringCap: CGFloat {
        min(max((2 * .pi * ringRadius / ringPitch).rounded(), 7), 64)
    }

    /// 圆柱半径（弦长公式 pitch = 2R·sin(step/2)；r35：pitch 换回
    /// 卡宽×1.14 后标准档 169.86/(2·sin20°) ≈ 248pt，
    /// compact ≈ 235pt，large ≈ 273pt；r31 的 218/206/240pt 是
    /// pitch=卡宽时的旧值，已作废）。
    var ringRadius: CGFloat {
        ringPitch / (2 * sin(ringStep * .pi / 360))
    }

    /// 透视距离 P = max(3.2R, 520)（壳版 ring.js openRing 原式：
    /// `P = Math.max(R * 3.2, 520)`；标准档 3.2×248 ≈ 795pt > 520，
    /// 三档都取 3.2R）。卡片旋转不再用 SwiftUI perspective 0.5，
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
        guard !tracks.isEmpty, flatSetWidth > 0, !flatDragging,
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
        guard !tracks.isEmpty, flatSetWidth > 0, !flatDragging,
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
            DiagLog.shared.recordLog(category: "marquee", message: "flat belt stuck 3s, watchdog driving", fields: ["tracks": tracks.count, "setWidth": flatSetWidth, "isDragging": flatDragging, "ringPhase": String(describing: ringPhase), "dwellSeconds": max(0, flatDwellUntil.timeIntervalSinceNow), "dwellReason": flatDwellReason, "offsetX": flatOffsetX, "speed": marqueeSpeed, "linkDeaths": flatLinkDeaths, "linkSilentSeconds": Date().timeIntervalSince(flatLastLinkFire)])
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
        guard !tracks.isEmpty, flatPitch > 0 else { return 0 }
        let pos = (x - flatCard / 2 - flatOffsetX) / flatPitch
        return mod(Int(pos.rounded()), tracks.count)
    }

    /// r33，第 4/11 件：带子点按命中校验——点按必须落在某张卡的矩形内才算
    /// 点中那首歌；卡缝（flatGap 16pt）与带上空白处不播歌。之前缺这道校验：
    /// 触摸层盖住整条带，任意点按都按最近卡播歌（点卡缝、点空白也播）。
    /// 环覆盖层同款做法（`hitTestRingCard`：点空处只关环不播歌），带子
    /// 这里补齐。中心算法与 `anchorNearestFlatCard` 同源（未取模的最近
    /// 槽位中心，2n 复制带上的副本位置同样算得准）。
    func isTapOnFlatCard(x: CGFloat) -> Bool {
        guard !tracks.isEmpty, flatPitch > 0 else { return false }
        let pos = (x - flatCard / 2 - flatOffsetX) / flatPitch
        let nearest = Int(pos.rounded())
        let centerX = flatOffsetX + CGFloat(nearest) * flatPitch + flatCard / 2
        return abs(x - centerX) <= flatCard / 2
    }

    /// 平面带正中间那张卡的下标（r28：入口按钮已删，本函数暂无调用方，留作备用）。
    func centerCardIndex() -> Int {
        guard !tracks.isEmpty else { return 0 }
        let cx = stripSize.width > 0 ? stripSize.width / 2 : flatCard / 2
        return anchorNearestFlatCard(x: cx)
    }

    // MARK: 平面带触摸状态机（壳版 ring.js onPressMove strip 分支，
    // 由 StripTouchView 的 UIPanGestureRecognizer 驱动；x/y 均为平面带本地坐标）

    /// 平面带触摸的移动结果：`.failGesture` = 竖向占优，
    /// 识别器自毁、把手势交还 ScrollView（ring.js「下滑 = 交还页面」同款；
    /// r24 起上/下都交还，上滑开环已删，见 stripTouchMoved）。
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

    /// 手指移动（pan .changed；r24 重写，第 3 件）：
    /// - 环已开（同一根手指）：环拖动还没走出 5px 之前，下滑 >90px 且
    ///   竖向占优 → 收回（ring.js onPressMove ring 分支「明显向下滑 =
    ///   退出环」；5px 死区是 RING_THRESHOLD）；否则继续转环。
    /// - 环没开：10px 内不判方向（ring.js DRAG_THRESHOLD=10）；
    ///   横向占优（|dx|>|dy|×1.25）→ 开环（锚点 = 手指下最近的卡，
    ///   ring.js nearestFlatIdx；手指不抬起继续拖就是转环，
    ///   ring.js enterRing 同款语义）；
    ///   竖向占优（上/下都一样）→ `.failGesture`（识别器自毁，
    ///   ScrollView 接管滚页面；上滑开环这一步按用户指令已删掉，
    ///   视频 0.9–1.0s 的上滑展开不再是必要步骤）。
    /// - 平面带不再支持横向手滚（横向拖动现在开环；跑马带本身
    ///   自动 24px/s 走，见 tickFlat）。
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
            if abs(dx) > abs(dy) * 1.25 {
                let anchor = anchorNearestFlatCard(x: x)
                openRing(anchor: anchor, atX: x, atY: y)
                press.decided = .openedRing
                stripPress = press
                return .handled
            }
            press.decided = .handedToScroll
            stripPress = press
            return .failGesture
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

    /// 开环（r28：入口只剩一处——平面带横向拖动 stripTouchMoved；
    ///   入口按钮点按已删，上滑入口 r24 已删）。
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
        guard ringPhase == .closed, !tracks.isEmpty else { return }
        anchorIndex = playingIndex ?? (tracks.indices.contains(anchor) ? anchor : 0)
        angle = 0
        entryT = 0
        closeT = 0
        overlayOpacity = 0
        ringPhase = .open
        ringDragging = false // 上次拖动若被系统打断残留了 true，先清掉再起新拖动
        isRingDragging = false
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
    /// 220ms 后恢复自动走（壳版 finishClose 同款）。
    func closeRing(quick: Bool = false) {
        guard ringPhase == .open else { return }
        ringPhase = .closing
        closeGeneration += 1
        entryGeneration += 1 // r33，第 5 条：还没跑的 deferred 展开动画作废
        ringDragging = false
        isRingDragging = false
        closeT = 0
        let ms = quick ? Self.quickCloseMs : Self.closeMs
        withAnimation(.timingCurve(0.32, 0, 0.67, 0, duration: ms / 1000)) {
            closeT = 1
        }
        withAnimation(.easeOut(duration: ms / 1000)) {
            overlayOpacity = 0
        }
        let gen = closeGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ms * 1_000_000) + 140_000_000)
            guard gen == self.closeGeneration else { return }
            self.ringPhase = .closed
            self.entryT = 0
            self.closeT = 0
            self.flatDwellUntil = Date().addingTimeInterval(Self.closeResumeMs / 1000)
            self.flatDwellReason = "close-done" // r34：看门狗日志报重停原因
        }
    }

    // MARK: 环拖动 / 松手

    /// 覆盖层手指刚落下（还没动）：只取消待执行的松手收回
    /// （ring.js onOverlayDown → beginPress → clearHold 同款；
    /// 拖动本身 5px 后才由 ringDragStart 接管，见 RingTouchView）。
    func ringTouchBegan() {
        guard ringPhase == .open else { return }
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
    func ringDragStart(x: CGFloat, y: CGFloat? = nil) {
        guard ringPhase == .open, !ringDragging else { return }
        ringDragging = true
        isRingDragging = true
        ringStartAngle = angle
        ringStartX = x
        ringDragStartY = y ?? ringOpenY
        ringSamples = [(Date(), angle)]
        closeGeneration += 1
    }

    func ringDragMoved(toX x: CGFloat) {
        guard ringPhase == .open, ringDragging else { return }
        angle = ringStartAngle + (x - ringStartX) * ringPerPixel
        let now = Date()
        ringSamples.append((now, angle))
        while ringSamples.count > 2,
              now.timeIntervalSince(ringSamples[0].time) > Self.sampleMs {
            ringSamples.removeFirst()
        }
        // r33 联动：拖动环时下面那排跟着动——带子偏移实时跟环中心走
        // （同一当前索引；环收回后带子从这首继续自动滚，开关环不丢位置）。
        syncFlatOffsetToRingCenter()
        // r33，第 2 条：中心槽位变了就预取新中心前后各 5 槽的封面。
        let cs = ringCenterSlot
        if cs != lastPrefetchCenterSlot {
            lastPrefetchCenterSlot = cs
            prefetchRingCovers(aroundCenterSlot: cs)
        }
    }

    /// 松手：最近 110ms 角速度（限幅 ±1400°/s）投影目标槽位，
    /// 临界阻尼弹簧（stiffness 118 → response ≈ 2π/√118 ≈ 0.58s）
    /// 吸附到最近槽位中心；随后保持 1000ms 再收回。
    /// 与壳版唯一差别：SwiftUI spring 不吃初速度，初速度已折进目标槽位
    /// （projected），弹簧只负责走过去，不另做 overshoot。
    func ringDragEnded() {
        guard ringPhase == .open else { return }
        ringDragging = false
        isRingDragging = false
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
        if abs(v) < 1 {
            let moved = angle - ringStartAngle
            if abs(moved) >= ringStep * 0.22 {
                projected += (moved > 0 ? 1 : -1) * ringStep * 0.28
            }
        }
        let targetAngle = -CGFloat(Int((-projected / ringStep).rounded())) * ringStep
        if abs(targetAngle - angle) < 1e-6, abs(v) < 1 {
            angle = targetAngle
        } else {
            withAnimation(.spring(response: 0.58, dampingFraction: 1.0)) {
                angle = targetAngle
            }
        }
        // r33，第 2 条：弹簧落点那首前后各 5 槽的封面提前取（落点槽位在
        // 弹簧动画里才走到，onChange(of: angle) 的带子同步会跟过去；
        // 封面预取按落点槽位先走，不等弹簧走完）。
        let targetSlot = Int((-targetAngle / ringStep).rounded())
        if targetSlot != lastPrefetchCenterSlot {
            lastPrefetchCenterSlot = targetSlot
            prefetchRingCovers(aroundCenterSlot: targetSlot)
        }
        scheduleHoldClose()
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
        guard !tracks.isEmpty else { return }
        let center = mod(anchorIndex + cs, tracks.count)
        var urls: [URL] = []
        urls.reserveCapacity(radius * 2 + 1)
        for d in -radius...radius {
            let idx = mod(center + d, tracks.count)
            if let url = tracks[idx].coverURL { urls.append(url) }
        }
        for url in urls {
            Task.detached { _ = await CoverImageLoader.shared.image(for: url) }
        }
    }

    /// 把平面带的偏移同步到环中心（r33 联动：环与带子共用同一个当前索引）：
    /// 带子中心对准环当前那首。拖动环时带子实时跟过去（ringDragMoved 调），
    /// 弹簧吸附时由覆盖层的 onChange(of: angle) 跟过去；环收回后带子从这首
    /// 继续自动滚（closeResumeMs 后 tickFlat 接着走），开关环不丢位置。
    /// 开环时不同步——带子在 0.26s 淡出里跳变会闪一下；环中心开环锚点
    /// （在播曲目/手指卡）与带子中心本来就允许不同，拖起来再合流。
    /// 带子宽还没量到（stripSize = 0）时跳过，不写脏偏移。
    /// 覆盖层没淡入满（overlayOpacity < 0.99，刚开环 0.26s 内）也不动——
    /// 带子还没藏好，中心差几首时一次跳几百 pt 会闪给用户看；淡入满后
    /// 带子已不可见，随便跳。弹簧阶段同步时淡入早已满，不受影响。
    func syncFlatOffsetToRingCenter() {
        guard !tracks.isEmpty, flatSetWidth > 0, stripSize.width > 0,
              overlayOpacity >= 0.99 else { return }
        let k = ringCenterTrackIndex
        let target = stripSize.width / 2 - flatCard / 2 - CGFloat(k) * flatPitch
        let next = normalizedFlat(target)
        guard abs(next - flatOffsetX) > 0.01 else { return }
        flatOffsetX = next
    }

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
        guard tracks.indices.contains(index) else { return }
        store.setQueue(tracks, startAt: index)
    }

    /// 点环卡：播歌 + 收回环（壳版 selectItem 同款）。
    func tapRingCard(trackIndex: Int, store: PlaybackStore) {
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

    /// 可见槽位：一次只见 3 张（实拍 f_050 也是 3 张：左一张切半、中间完整、
    /// 右一张切半；r30 v5 图口径同值）——中心槽前后各一格
    /// （world ±40°）；|world| ≤ 86.5°（facing > 0.06）仍作第二道防线，
    /// 同一首歌只出现一次（曲目 < 3 首时不复制，壳版 n = min(曲数, 环容量) 同款）。
    /// 旧的中心±2 会在转环半途多露一格（world ±60° 在屏边各剩约 12pt 边角；
    /// r31 起环层全屏宽不裁切，±60° 的卡真会露出来，所以仍收成 3 张）。
    func visibleSlots() -> [RingSlot] {
        guard !tracks.isEmpty else { return [] }
        let q = -angle / ringStep
        let center = Int(q.rounded())
        var seen = Set<Int>()
        var out: [RingSlot] = []
        for s in (center - 1)...(center + 1) {
            let world = (CGFloat(s) - q) * ringStep
            guard abs(world) <= 86.5 else { continue }
            let idx = mod(anchorIndex + s, tracks.count)
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

    /// 远端压暗（壳版：0.55·((1-facing)/2)^1.25）。保留作壳版对照值——
    /// r33 起环卡不再用它直接盖一层平色，见 shadeFarEdge。
    func shadeOpacity(facing: CGFloat) -> Double {
        0.55 * pow(Double((1 - facing) / 2), 1.25)
    }

    /// 侧卡远缘压暗（r33，第 1 条：沿卡面横向渐变的远缘黑度，近缘 0 → 远缘本值）。
    /// 壳版 flat shade 在 40° 槽位只有 3.8%（0.55·((1−cos40°)/2)^1.25），
    /// 壳版靠 CSS 透视梯形补立体感所以够用；原生 r31 的正交旋转没有梯形，
    /// 3.8% 肉眼不可见——实测 f_010 侧卡亮度只比中心卡低约 7%（音符占位
    /// 本身也有明暗），三张卡看着就是平铺重叠。圆柱面的明暗本来就该沿
    /// 卡面渐变（远缘更暗），这里按 (1−facing) 线性拉到 40° 槽位远缘 0.42：
    /// 中心卡 facing=1 → 0 不压暗；40° 侧卡近缘 0、远缘 0.42、平均约 0.21，
    /// 肉眼可辨、又不至于把封面盖死。不是壳版原值（原值 3.8% 见 shadeOpacity），
    /// 是原生缺梯形时的视觉补偿，真机确认强度，见 r33.cjs 断言建议。
    func shadeFarEdge(facing: CGFloat) -> Double {
        guard facing < 1 else { return 0 }
        let unit = (1 - Double(facing)) / (1 - cos(40 * .pi / 180))
        return min(0.42, 0.42 * unit)
    }

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

    /// 相机 -5° 下坠（r26-3D，壳版 camera `translateZ(-R) rotateX(-5°)`）：
    /// 正前方卡片的 z = R，绕 X 轴 -5° 后纵向掉 R·sin5°（标准档约 20pt；
    /// 视频实测环中心比带中心低约 28–33pt，公式值 20pt，残差在量取误差内）。
    /// 某槽位的 z = R·cos(world) = R·facing，下坠跟着 facing 走；
    /// 原生之前把环卡排在 z=0 的平面上、容器 rotateX(-5°) 实际不产生下坠，
    /// 环整体比视频高约 20pt。展开/收回中跟有效半径走（R 收缩时下坠同缩）。
    func tiltDrop(facing: CGFloat) -> CGFloat {
        effectiveRadius() * facing * sin(5 * .pi / 180)
    }

    /// 环中心纵坐标（r34 重写：渲染不再用它，见 ringCardCenterYLocal）。
    /// 只剩变暗中心用：变暗光晕的中心 = 环视觉中心 = 中心卡的卡中心
    /// （盖面中心 + 23pt 文字段 - tiltDrop 抵消后 = stripCenter.y - 3pt，
    /// 见 ringCenterY 的推导）。stripCenter 还没量到时回落屏高 ×0.62
    /// （r24 同款）；`topEdge` 不再用于夹取，保留参数免得改调用点。
    /// r31 的教训仍在：不要把 ring.js 的 cy 上下限夹取搬回来——Hero 拖大后
    /// 带心远超旧上限，夹取就是把环钉在固定高度、与带子脱节。
    func ringCenterY(screenHeight: CGFloat, topEdge: CGFloat) -> CGFloat {
        _ = topEdge
        return stripCenter.y > 0 ? stripCenter.y - 3 : screenHeight * 0.62
    }

    /// 环卡中心纵坐标（带内局部坐标，r34，第 2/4 件：环就定在平带卡片的位置）。
    /// 带内原点 = 带顶，带高 flatHeight = flatCard + 52；平带盖面中心在
    /// flatCard/2。环卡是 VStack（封面 ringCard + 5 + 歌名 + 5 + 歌手，
    /// 总高 ringCardHeight = ringCard + 46），盖面中心比卡中心高
    /// (ringCardHeight - ringCard) / 2 = 23pt；相机 -5° 再把每张卡往下推
    /// 各自的 tiltDrop（正前方最大，越靠两侧越小）。
    /// 中心卡盖面中心对齐平带盖面中心：
    ///   卡中心 = flatCard/2 + 23 - tiltDrop(1.0) + tiltDrop(facing)
    /// 展开/收回中 tiltDrop 跟有效半径走：中心卡盖面中心全程钉在
    /// flatCard/2（只长尺寸、不挪位置——就是“原地变成 3D”），
    /// 侧卡盖面中心比中心卡高 tiltDrop(1.0) - tiltDrop(facing)
    /// （40° 时约 4.7pt，壳版相机 -5° 同款弧线）。
    /// 旧锚点 cy = stripCenter.y 的问题：它把卡中心当成盖面中心，
    /// 自带 23pt 上偏（r33 视频实测环盖比平盖高约 118pt，其中 23pt
    /// 是这笔账，剩下约 95pt 是存下来的 stripCenter 本身不准——见文件头 r34）。
    /// 本函数只用 flatCard / tiltDrop，不读 stripCenter：渲染不再依赖
    /// 存下来的锚点，带子在哪、环就在哪。
    func ringCardCenterYLocal(forWorld world: CGFloat) -> CGFloat {
        flatCard / 2 + (ringCardHeight - ringCard) / 2
            - tiltDrop(facing: 1) + tiltDrop(facing: facing(forWorld: world))
    }

    /// 环卡中心纵坐标（屏坐标 / liziHome 坐标，点按命中用，与渲染同公式）：
    /// 中心卡卡中心 = 带顶 + 平盖中心 + 23pt 文字段（带顶 = stripCenter.y -
    /// flatHeight/2）；各槽卡中心 = 中心卡卡中心 - tiltDrop(1.0) + tiltDrop(facing)。
    /// stripCenter 还没量到时中心卡卡中心回落 ringCenterY（屏高 ×0.62 那条），
    /// 命中盒跟着变暗中心走，不拿 y=0 去比。
    func ringCardCenterScreenY(forWorld world: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let centerCardY: CGFloat
        if stripCenter.y > 0 {
            centerCardY = stripCenter.y - flatHeight / 2 + flatCard / 2 + (ringCardHeight - ringCard) / 2
        } else {
            centerCardY = ringCenterY(screenHeight: screenHeight, topEdge: 95)
        }
        return centerCardY - tiltDrop(facing: 1) + tiltDrop(facing: facing(forWorld: world))
    }

    /// 面板横向范围（r31 真圆柱：halfWidth 不再用于裁切——r30 v5 图的
    /// 面板圆角裁切作废，实拍 f_050/f_060/f_070 里侧卡都溢出面板到屏边，
    /// 环层改全屏宽；halfWidth 只保留作参考，不再拦点按、不再框环层）：
    /// 面板外缘 = 带子外缘各扩 20pt（dailyPanel padding 10 + 本文件
    /// body 的 VStack padding 10，见 HomeView.dailyPanel）；面板与带子
    /// 同中心（stripCenter.x）。带子还没量到（stripSize = 0）时回落
    /// 屏宽/2 − 16（f_001 面板左右边距约 16pt）。
    /// - 返回：(面板中心 x，面板半宽)，liziHome 坐标。
    func panelRect(screenWidth: CGFloat) -> (centerX: CGFloat, halfWidth: CGFloat) {
        let cx = stripCenter.x > 0 ? stripCenter.x : screenWidth / 2
        let half = stripSize.width > 0 ? stripSize.width / 2 + 20 : screenWidth / 2 - 16
        return (cx, half)
    }

    /// 点按命中：取包含该点、离正前方最近的卡（ring.js onPressUp 点选同款，
    /// 用包围盒近似旋转后的卡）。
    /// r34：纵向锚点与渲染同公式（`ringCardCenterScreenY`：中心卡卡中心 =
    /// 带顶 + 平盖中心 + 23pt 文字段，各槽再按 tiltDrop 偏）——命中盒与
    /// 眼睛看到的卡片位置一致；旧的 `ringCenterY + tiltDrop` 是错的
    /// （它把卡中心当成盖面中心，自带 23pt 上偏，见 ringCardCenterYLocal）。
    /// r31 真圆柱：横向锚点与渲染同款——panel.centerX（环跟着面板走；
    /// 旧的 screenWidth/2 与渲染锚点不是同一个，面板偏移时点按盒会错位），
    /// 横向位置与渲染同款 projectedX（透视投影后的位置，不是 R·sin），
    /// 面板外拦截删掉（侧卡溢出面板到屏边，溢出部分看得见、点得到）。
    func hitTestRingCard(at point: CGPoint, screenWidth: CGFloat, screenHeight: CGFloat? = nil, topEdge: CGFloat = 95) -> Int? {
        _ = topEdge
        let panel = panelRect(screenWidth: screenWidth)
        let cx = panel.centerX
        var best: (index: Int, world: CGFloat)?
        for slot in visibleSlots() {
            let x = cx + projectedX(forWorld: slot.world)
            let slotCy = ringCardCenterScreenY(forWorld: slot.world, screenHeight: screenHeight ?? 0)
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

/// 平面带按压判定（r24：第 3 件后只剩三种——没判向、已开环、已交还 ScrollView；
/// 旧的 `.horizontal`（横向手滚跑马带）与 `.vertical`（上滑开环）已随
/// 上滑门槛一起删掉）。
struct StripPress {
    var startX: CGFloat
    var startY: CGFloat
    var decided: StripDecision
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
    var dailyEmptyReason: String?
    /// 跑马带速度（调用方传 `viewModel.marqSpeedPxPerSecond`，默认 24）。
    var marqueeSpeed: CGFloat = 24
    /// 尺寸档（调用方按实测屏宽经 `PlayerTokens.sizeTier(for:topInset:)` 传入）。
    var tier: PlayerTokens.PlayerSizeTier = .standard
    /// 面板深场（调用方传 HomeView 的专辑取色 field；默认深场）。
    var panelIsDark = true

    var body: some View {
        Group {
            if model.tracks.isEmpty {
                if model.isLoadingDaily {
                    loadingView
                } else {
                    emptyView
                }
            } else {
                // 平面带 + 入口提示行（r22c）：提示行是环的可见入口
                // （r28：「展开 3D 环」按钮已删，点按开环不在触发里；
                // 只留提示文字 + 平面带横向拖动开环）。
                // r28：外面一块更深的圆角底（黑 0.18）——39.6s 视频 f_001
                // 里卡行就在一块比面板再暗一档的圆角底上。
                VStack(alignment: .leading, spacing: 6) {
                    flatStrip
                    entryHintRow
                }
                .padding(10)
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
        .onChange(of: playback.currentTrack) { _ in sync() }
        .onChange(of: isLoadingDaily) { _ in sync() }
        .onChange(of: dailyEmptyReason) { _ in sync() }
        .onChange(of: marqueeSpeed) { _ in sync() }
        .onChange(of: tier) { _ in sync() }
        .onChange(of: panelIsDark) { _ in sync() }
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
            emptyReason: dailyEmptyReason,
            playing: playback.currentTrack,
            speed: marqueeSpeed,
            tier: tier,
            panelIsDark: panelIsDark
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
                            ForEach(model.tracks.indices, id: \.self) { i in
                                FlatRingCard(track: model.tracks[i], width: model.flatCard, isDark: model.panelIsDark) {
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
                .offset(x: model.flatOffsetX)
                .onPreferenceChange(FlatSetWidthKey.self) {
                    // r34，第 1 件——布局完成前偏好先报 0，旧代码直接写成
                    // 0+16=16，带子只能在 16pt 里打转、看着就是冻住。
                    // 小于一份宽度只可能是布局前的残值，忽略，等布局完成
                    // 后的足额上报（syncInputs 里同一道兜底，见模型）。
                    let w = $0 + model.flatGap
                    if w >= CGFloat(model.tracks.count) * (model.flatCard + model.flatGap) {
                        model.flatSetWidth = w
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: model.flatHeight, alignment: .top)
            .clipped()
            .opacity(1 - model.overlayOpacity)
            // 环层（r34，第 2/4 件）：就地环——不是覆盖层，是带子里的
            // 另一层；与平带共用同一份 model.tracks、同一套 visibleSlots/
            // angle/anchorIndex、同一个容器。环闭合时不挂载，透明度跟
            // overlayOpacity（展开 0.26s 淡入、收回跟 closeT 淡出）。
            // 侧卡溢出带子贴到面板边是设计（壳版同款），外层 ZStack
            // 不裁切；面板圆角底座在 body 的 VStack 上，不裁内容。
            if model.ringPhase != .closed {
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
    /// 纵向下坠已经由 tiltDrop 表达，这里只补卡面后仰——旧代码的
    /// 容器 rotateX(-5°) 是双算，还把 perspective 0.5 强透视带进来，
    /// r30 已删；卡面本身一直没有后仰，侧卡才看着像平面排布）。
    /// 压暗两层叠加：整卡盖壳版公式平色（shadeOpacity，40° 时 3.8%）+
    /// 封面远缘渐变（shadeFarEdge，40° 时 0.42，r33 视觉补偿）。
    /// 展开/收回中 depthScale/cameraScale/tiltDrop 都跟有效半径走，
    /// 环从平面里长出来、收回平面里（r31 同款）。
    private var ringLayerInStrip: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(model.visibleSlots()) { slot in
                    let track = model.tracks[slot.trackIndex]
                    let facing = model.facing(forWorld: slot.world)
                    RingCardView(
                        track: track,
                        width: model.ringCard,
                        world: slot.world,
                        shadeFar: model.shadeFarEdge(facing: facing),
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
                        x: geo.size.width / 2 + model.projectedX(forWorld: slot.world),
                        y: model.ringCardCenterYLocal(forWorld: slot.world)
                    )
                    .zIndex(Double(100 - abs(slot.world)))
                    .accessibilityLabel("播放：\(track.title)")
                }
            }
            .frame(width: geo.size.width, height: model.flatHeight)
        }
        .frame(height: model.flatHeight)
    }

    /// 入口提示行：只剩手势提示文字（「拖动展开 3D 环 · 拖动旋转」），
    /// 不再有按钮。
    /// r24：第 3 件后提示改成拖动（上滑入口已删，chevron.up 图标也换掉，
    /// 别再暗示用户去上滑）。
    /// r28：「展开 3D 环」按钮已删（点按开环不在 r24 定好的触发里）；
    /// 开环只剩平面带横向拖动（`stripTouchMoved` → `openRing`），
    /// 不加替代的提示按钮；颜色跟面板深场走（深场白字，浅场墨字）。
    private var entryHintRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
            Text("拖动展开 3D 环 · 拖动旋转")
                .font(.liziBody(size: LiziTokens.size12))
        }
        .foregroundColor(model.panelIsDark ? .white.opacity(0.75) : LiziTokens.ink3)
        .opacity(1 - model.overlayOpacity) // r34：环开着时提示行跟平带一起淡出
    }
}

/// 平面带里的一张卡：封面 + 歌名 + 歌手（r28：卡宽按档走 180/190/209；
/// 歌名 16pt、歌手 14pt，39.6s 新视频实测；颜色跟面板深场走——
/// 深场白字 + 灰字，浅场墨字）。
///
/// 不是 Button：带子的触摸层（`StripTouchView`，盖在卡片上方）统一接管点按；
/// Button 和识别器的 tap 会双重触发。VoiceOver 激活走 `.accessibilityAction`。
private struct FlatRingCard: View {
    let track: Track
    let width: CGFloat
    let isDark: Bool
    let onTap: () -> Void

    /// r30：没封面（coverURL 为 nil）不摆白卡——深色默认封面（壳版
    /// `.mring__card.is-empty` 深色底 +「无封面」同款做法；原生占位图标
    /// 沿用 music.note，只把白底换成深色渐变）。URL 有但加载失败的白占位
    /// 在 CoverImageView.swift 里，本文件动不了。
    @ViewBuilder
    private var coverArt: some View {
        if track.coverURL == nil {
            DefaultCoverArt(iconSize: 64)
        } else {
            CoverImageView(url: track.coverURL, placeholderIconSize: 64)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            coverArt
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius10))
            Text(track.title)
                .font(.liziBody(size: LiziTokens.size16, weight: .medium))
                .foregroundColor(isDark ? .white : LiziTokens.ink)
                .lineLimit(1)
            Text(track.artist)
                .font(.liziBody(size: LiziTokens.size14))
                .foregroundColor(isDark ? .white.opacity(0.62) : LiziTokens.ink3)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("播放：\(track.title)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
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
            let ringTopEdge: CGFloat = geo.size.width > geo.size.height ? 64 : 95
            let ringCy = model.ringCenterY(screenHeight: geo.size.height, topEdge: ringTopEdge)
            let ringCx = model.panelRect(screenWidth: geo.size.width).centerX
            ZStack {
                // 全屏径向变暗（r31：中心跟环走，不再是固定 50% / 48%；
                // 三档 0.36/0.58/0.78 与半径不动）。
                radialScrim(size: geo.size, centerX: ringCx, centerY: ringCy)
                // 拖动时顶部再暗一档（视频：拖动时顶部大卡片变暗；常态开环
                // 已有上面的径向变暗，这一层只在手指转环时出现）。
                LinearGradient(
                    gradient: Gradient(colors: [
                        .black.opacity(0.14), .black.opacity(0.0),
                    ]),
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: geo.size.height * 0.55)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(model.isRingDragging ? 1 : 0)
                // r34：第 4 件——圆柱环已经搬进平带容器（flatStrip 里的
                // ringLayerInStrip），覆盖层不再画卡；这里只剩变暗 +
                // 底部提示 + 触摸层。
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
                // r26-3D：topEdge 与命中测试同值（顶栏底边），命中测试用
                // ringCardCenterScreenY（与渲染同公式），点按盒与眼睛
                // 看到的卡片位置一致。
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
        // r33 联动：弹簧吸附阶段 angle 还在动（ringDragMoved 不再调），
        // 每帧把带子偏移跟到环中心；拖动阶段 ringDragMoved 里已同步，
        // 这里重复调是空操作（syncFlatOffsetToRingCenter 里有 0.01 阈值守卫）。
        .onChange(of: model.angle) { _ in model.syncFlatOffsetToRingCenter() }
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
/// 压暗两层（r34，第 3 件）：封面远缘渐变（shadeFar，r33）+ 整卡壳版公式
/// 平色（shadeFlat，0.55·((1-facing)/2)^1.25，40° 时 3.8%）——壳版
/// `.mring__shade` 是 inset: 0 的整卡覆盖（含歌名行），原生之前只压
/// 封面、文字一行不压，就是“压暗弱”的实锤之一；平色层盖在整卡上，
/// 与封面渐变叠加。
///
/// r22c：文字左对齐——8 张截图里每张环卡的歌名/歌手都从卡片左缘起
/// （r21 的居中与截图不符；壳版 `.mring__name` 也是默认左对齐）。
private struct RingCardView: View {
    let track: Track
    let width: CGFloat
    /// 该槽的世界角（度）：正 = 右侧卡，负 = 左侧卡；决定渐变压暗的远缘方向。
    let world: CGFloat
    /// 远缘黑度（0…0.42，模型 `shadeFarEdge` 算出；中心卡为 0）。
    let shadeFar: Double
    /// 整卡平色黑度（0…1，模型 `shadeOpacity` 壳版公式算出；中心卡为 0）。
    let shadeFlat: Double

    /// r30：没封面（coverURL 为 nil）不摆白卡——深色默认封面（见 FlatRingCard
    /// coverArt 注释）。r33，第 2 条：URL 有但加载失败/还没到时也不摆白卡——
    /// CoverImageView 走深色占位（`darkPlaceholder`），环里绝不留浅灰音符占位。
    @ViewBuilder
    private var coverArt: some View {
        if track.coverURL == nil {
            DefaultCoverArt(iconSize: 48)
        } else {
            CoverImageView(url: track.coverURL, placeholderIconSize: 48, darkPlaceholder: true)
        }
    }

    /// 圆柱面明暗（r33，第 1 条）：沿卡面横向渐变，近缘 0 → 远缘 shadeFar。
    /// 右侧卡（world > 0）远缘在右，渐变左清右黑；左侧卡反之；中心卡不压暗。
    /// 旧的整面平色 3.8%（壳版公式原值）在正交旋转下肉眼不可见，见 shadeFarEdge 注释。
    private var shadeGradient: LinearGradient {
        if world > 0 {
            return LinearGradient(
                colors: [.black.opacity(0), .black.opacity(shadeFar)],
                startPoint: .leading, endPoint: .trailing
            )
        } else if world < 0 {
            return LinearGradient(
                colors: [.black.opacity(shadeFar), .black.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            coverArt
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(shadeGradient)
                )
                .shadow(color: .black.opacity(0.8), radius: 26, x: 0, y: 12)
            Text(track.title)
                .font(.liziBody(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.55), radius: 8, x: 0, y: 1)
            Text(track.artist)
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
/// 全部触摸（点按 + 横向滚带 + 上滑开环 + 开环后继续转环）。
///
/// 为什么不用 SwiftUI DragGesture（r21 的教训）：带子在竖向 ScrollView 里，
/// `.simultaneousGesture(DragGesture)` 在真机上拦不住 ScrollView 的竖滑——
/// 上滑开环的手势会被页面滚动抢走，`openRing` 根本到不了，环打不开。
/// 壳版的等价物是 `.mstrip { touch-action: none; }`（见 public/m/m.css），
/// 即带子拥有全部触摸；这里用 UIKit 识别器复刻同一条语义：
/// - `shouldBeRequiredToFailBy`：ScrollView 的 pan 必须等我们的 pan 先失败
///   才开始滚页面——横向由我们接管（r24：第 3 件后横向 = 开环+转环），
///   页面滚不动；
/// - 方向判定后是竖向（上/下都一样）：我们的 pan 自毁（`isEnabled` 开关一次），
///   ScrollView 接管，页面接着滚（ring.js「下滑 = 交还页面」同款；
///   上滑开环已按用户指令删掉，见模型 `stripTouchMoved`）；
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

    /// ScrollView 的 pan 必须等我们的 pan 先失败：上滑/横向由我们接管，
    /// 页面滚不动；只有我们判定为竖向下滑而自毁后，页面才接着滚。
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
                model.ringDragEnded()
            } else {
                // r33，第 3 条：没拖起来（<5px 晃一下就抬手）也要补一个
                // 松手收回——touchesBegan 已经取消了待执行的收回定时器，
                // 这次触摸既没走 ringDragEnded、又没走点按（pan 认出来了，
                // tap 不触发），不补定时器环就永远开着。
                model.ringTouchEnded()
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

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let model, recognizer.state == .ended else { return }
        guard model.ringPhase == .open else { return }
        let location = recognizer.location(in: self)
        if let idx = model.hitTestRingCard(at: location, screenWidth: bounds.width, screenHeight: bounds.height, topEdge: topEdge) {
            onTapCard?(idx)
        } else {
            onTapBlank?()
        }
    }
}
