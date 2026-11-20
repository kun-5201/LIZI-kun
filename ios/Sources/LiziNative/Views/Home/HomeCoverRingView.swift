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
/// 圆柱：pitch=卡宽×1.14（壳版）→ 视频实测 pitch≈卡宽（见下），R 取
/// 弦长公式；透视 P=3.2R；相机 translateZ(-R) rotateX(-5°)；
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
///   命中测试与 ringLayer 共用 ringCenterY，点按盒跟着走。
///   夹取删除后，带子被滚到屏顶/屏底边缘时环跟着过去（可能半遮顶栏
///   或出屏），这是「跟着面板走」的本意；环开着时覆盖层挡住触摸，
///   本来也滚不动页面、拖不了分界手柄，面板动只剩旋转与布局变化。
/// - 不动：转动机制（跟手 perPixel、110ms 采样 ±1400°/s、τ=1.08s 投影 +
///   弹簧 118 吸附、只露正面、收回时机）、展开手势（跑马带左右拖动，
///   不要上滑）、变暗三档、一次 3 张、面板裁切。驱动见
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
///   丢帧后下一步自动补上，位移严格按速度×时间走；回调经弱引用
///   代理跳主线程（display link 强持 target，不用代理模型永远不释放，
///   见 `FlatDisplayLinkProxy`）。初画停 2.5s、松手 1.2s 恢复、
///   10s 看门狗、环开着停带、速度 24px/s 一律不动。
///   取色已核过：AlbumToneExtractor 是 32×32 采样 + k=4 最多 10 轮，
///   毫秒级，且只在切歌时跑一次，不是卡顿来源，不动它；
///   实现是 offset 位移（不是 ScrollView 编程式滚动），没有 layout
///   跳变；回卷只按一份宽度归一化，不跳整张卡宽。
/// - DefaultCoverArt 去掉 private：其余 5 个来源的跑马带卡片共用同一份
///   默认封面（见 HomeView.swift `RailMarqueeCardView`）。环的几何、
///   开环触发（只剩平面带横向拖动）、收回、变暗一律不动。

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
    /// 平面跑马带驱动（r31：r26 的 30Hz Timer → CADisplayLink，见文件头）：
    /// 一次创建、`.common` 模式；display link 经 RunLoop 强持，模型走了
    /// 它不会跟着走——回调走弱引用代理（`FlatDisplayLinkProxy`），不让
    /// link 强持模型造成循环引用；HomeView 每次切页回来都重建
    /// （RootView `.home` 分支新建 HomeView → 新 HomeCoverRingModel），
    /// 模型释放时 deinit 停表，不停每回首页漏一个空转驱动。
    /// 上一帧时间戳（回调算 dt 用；0 = 还没走过第一帧）。
    private var flatDisplayLink: CADisplayLink?
    private var flatLinkProxy: FlatDisplayLinkProxy?
    private var flatLastTimestamp: CFTimeInterval = 0

    /// 模型走时停掉自己的 display link（r26 补 Timer 版，r31 同款）：
    /// 不停，RunLoop 会一直强持它空转；停了，下次回首页新模型重新
    /// startFlatTimer，不影响跑马带恢复。
    deinit { flatDisplayLink?.invalidate() }
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

    var isRingOpen: Bool { ringPhase == .open }

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

    /// 相邻槽位夹角 40°（视频实测侧卡倾角）。
    var ringStep: CGFloat { 40 }

    /// 槽距 = 卡宽×1.14（壳版 ring.js；39.6s 视频侧卡 ±40° 倾角下此槽距
    /// 不重叠；旧视频的 pitch=卡宽已作废）。
    var ringPitch: CGFloat { ringCard * 1.14 }

    /// 圆柱半径（弦长公式 pitch = 2R·sin(step/2)）。
    var ringRadius: CGFloat {
        ringPitch / (2 * sin(ringStep * .pi / 360))
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
    /// 与旧 Timer 的 `.common` 同款）；回调经弱引用代理进主线程
    /// （`FlatDisplayLinkProxy`，display link 强持 target，不代理就漏），
    /// 步长在 tickFlat 里按真实帧间隔 dt 算。
    func startFlatTimer() {
        guard flatDisplayLink == nil else { return }
        let proxy = FlatDisplayLinkProxy(model: self)
        let link = CADisplayLink(target: proxy, selector: #selector(FlatDisplayLinkProxy.fired(_:)))
        link.add(to: .main, forMode: .common)
        flatLinkProxy = proxy
        flatDisplayLink = link
    }

    /// display link 回调（主线程）：按真实帧间隔 dt 推进跑马带。
    /// dt 从 link.timestamp 差算（不是回调到达时间，所以 Task 跳主线程
    /// 的几毫秒延迟不扭曲步长）；第一帧没有上一帧，用 1/60s 起步。
    /// r31 前是 30Hz Timer：每步 0.8px 离散跳变，肉眼一顿一顿。
    fileprivate func flatDisplayLinkFired(_ link: CADisplayLink) {
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
        // 展开 520ms（easeOutQuint 近似 timingCurve(0.22,1,0.36,1)），
        // 覆盖层 260ms 淡入（壳版 .mring transition opacity .26s）。
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.enterMs / 1000)) {
            entryT = 1
        }
        withAnimation(.easeOut(duration: 0.26)) {
            overlayOpacity = 1
        }
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

    /// 可见槽位：一次只见 3 张（r30 v5 图口径）——中心槽前后各一格
    /// （world ±40°）；|world| ≤ 86.5°（facing > 0.06）仍作第二道防线，
    /// 同一首歌只出现一次（曲目 < 3 首时不复制，壳版 n = min(曲数, 环容量) 同款）。
    /// 旧的中心±2 会在转环半途多露一格（world ±60° 在屏边各剩约 12pt 边角，
    /// 未裁切时看得见；面板裁切后虽出不来，仍按 v5 收成 3 张）。
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

    /// 远端压暗（壳版：0.55·((1-facing)/2)^1.25）。
    func shadeOpacity(facing: CGFloat) -> Double {
        0.55 * pow(Double((1 - facing) / 2), 1.25)
    }

    /// 透视缩放 P=3.2R：scale = 3.2 / (3.2 + (1-facing))。
    func depthScale(facing: CGFloat) -> CGFloat {
        3.2 / (3.2 + (1 - facing))
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

    /// 环中心纵坐标（r31，用户 2026-11-21 05:37 已定：环跟着面板走）：
    /// 就是带子中心 stripCenter.y，不再夹取——r26-3D 从 ring.js 照搬的
    /// 上下限（顶栏底 + 卡高×0.55 + 12 / 屏底 − 卡高×0.55 − 52 − 下坠）
    /// 在这里作废：Hero 拖大后带心约 775pt、横屏带心约 433pt，都远超
    /// 旧上限（竖屏 663 / 横屏 194），环会被钉在固定高度、与带子脱节
    /// （用户原话「中心钉在屏幕 0.5/0.48 不动」就是这副样子）。
    /// stripCenter 还没量到时回落屏高 ×0.62（r24 同款）；`topEdge`
    /// 不再用于夹取，保留参数免得改两处调用点（ringLayer / hitTestRingCard）。
    /// 锚点是活的：stripCenter 是 @Published，带子每动一帧（滚动、
    /// 拖分界手柄改尺寸、旋转）都经 StripCenterKey 偏好重报，body 重算，
    /// 环中心跟着走；不经 withAnimation，没有插值滞留与跳变。
    /// 命中测试与 ringLayer 用同一个函数，点按盒与眼睛看到的卡片一致。
    func ringCenterY(screenHeight: CGFloat, topEdge: CGFloat) -> CGFloat {
        _ = topEdge
        return stripCenter.y > 0 ? stripCenter.y : screenHeight * 0.62
    }

    /// 面板横向范围（r30 v5：侧卡由面板圆角 mask 裁切，不溢出面板外）：
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
    /// r24：纵向锚点与 ringLayer 同款回落——stripCenter 还没量到时
    /// （如按钮在布局前被点到）用屏高 ×0.62，不再拿 y=0 去比（那会让
    /// 点卡永远判空）；screenHeight 不传时回落 0，即只信 stripCenter。
    /// r26-3D：纵坐标与 ringLayer 用同一个 `ringCenterY`（r31 起不夹取，
    /// 跟带子走），再按槽位加各自的 `tiltDrop`（-5° 下坠，越靠两侧越小），命中盒与
    /// 眼睛看到的卡片位置一致；不加下坠时前排卡的命中盒会比实物高 20pt。
    func hitTestRingCard(at point: CGPoint, screenWidth: CGFloat, screenHeight: CGFloat? = nil, topEdge: CGFloat = 95) -> Int? {
        // r30：面板外的点按不算点卡（侧卡被面板裁掉的部分看不见，点那里
        // 应是点空白快收，不是点中被裁掉的卡）。
        let panel = panelRect(screenWidth: screenWidth)
        guard point.x >= panel.centerX - panel.halfWidth,
              point.x <= panel.centerX + panel.halfWidth else { return nil }
        let cx = screenWidth / 2
        let cy = ringCenterY(screenHeight: screenHeight ?? 0, topEdge: topEdge)
        let r = effectiveRadius()
        var best: (index: Int, world: CGFloat)?
        for slot in visibleSlots() {
            let x = cx + r * sin(slot.world * .pi / 180)
            let slotCy = cy + tiltDrop(facing: facing(forWorld: slot.world))
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
                // 环下面不再透出多余的专辑卡。opacity 不动布局，
                // stripCenter / stripSize 照常量，环的纵向锚点不受影响。
                .opacity(1 - model.overlayOpacity)
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
            .onPreferenceChange(FlatSetWidthKey.self) { model.flatSetWidth = $0 + model.flatGap }
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
        .clipped()
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
/// 回调在主线程 RunLoop 上触发，跳主线程用 `Task { @MainActor in }`
/// （与 r26 Timer 版同款写法）；dt 从 link.timestamp 算，不受这
/// 几毫秒延迟影响。
private final class FlatDisplayLinkProxy: NSObject {
    weak var model: HomeCoverRingModel?

    init(model: HomeCoverRingModel) {
        self.model = model
    }

    @objc func fired(_ link: CADisplayLink) {
        Task { @MainActor in self.model?.flatDisplayLinkFired(link) }
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
                // 圆柱环。
                ringLayer(screenWidth: geo.size.width, screenHeight: geo.size.height)
                // 底部提示（视频原字；壳版 .mring__hint：bottom max(16, safe+10)）。
                VStack {
                    Spacer()
                    Text("拖动旋转 · 点击播放 · 松手收回")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.74))
                        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 1)
                        .padding(.bottom, max(16, geo.safeAreaInsets.bottom + 10))
                }
                // r24：触摸层（RingTouchView，UIKit，文件尾）盖在最上层——
                // 整块覆盖层的触摸都归它：拖动转环、点卡播歌、点空白收回、
                // 下滑退出（ring.js onOverlayDown + window pointer 监听同款）。
                // 旧的 SwiftUI DragGesture + onTapGesture 已删（第 4 件根因：
                // 两者叠在同一视图上，真机上拖动到不了模型）。
                // r26-3D：topEdge 与 ringLayer 同值（顶栏底边），命中测试用
                // 同一个 ringCenterY，点按盒与眼睛看到的卡片位置一致。
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

    /// 圆柱环：容器框在环中心（平面带中心），卡按世界角排布；
    /// 容器整体 rotateX(-5°)（壳版 camera 同款），转轴就是环中心。
    /// r26-3D：纵向锚点走 `ringCenterY`（r31 起不夹取，环中心 = 带子中心）；每张卡再
    /// 下坠各自的 `tiltDrop`（相机 -5°，正前方约 20pt、两侧渐小）——
    /// 原生之前 z=0 平面排布、容器旋转不产生下坠，环整体比视频高约 20pt。
    /// r30 v5：环层按面板宽框住 + 圆角 22 裁切（dailyPanel 同值），侧卡
    /// 被面板左右边切半、不溢出面板外；层内坐标 = 面板坐标（子卡 x/y
    /// 各减面板左缘/上缘），卡中心纵向仍是 cy + tiltDrop，与旧版一致；
    /// 层高 = 卡高 + 上下各 40pt 阴影余量（封面阴影 radius 26 / y 12，
    /// 约 38pt，旧层高会把阴影下沿裁掉）。命中测试同步拦面板外点按
    /// （见 hitTestRingCard）。
    private func ringLayer(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let topEdge: CGFloat = screenWidth > screenHeight ? 64 : 95
        let cy = model.ringCenterY(screenHeight: screenHeight, topEdge: topEdge)
        let panel = model.panelRect(screenWidth: screenWidth)
        let panelMinX = panel.centerX - panel.halfWidth
        let r = model.effectiveRadius()
        let cam = model.cameraScale()
        let layerHeight = model.ringCardHeight + 80
        return ZStack {
            ForEach(model.visibleSlots()) { slot in
                let track = model.tracks[slot.trackIndex]
                let facing = model.facing(forWorld: slot.world)
                let x = panel.centerX + r * sin(slot.world * .pi / 180)
                RingCardView(
                    track: track,
                    width: model.ringCard,
                    shadeOpacity: model.shadeOpacity(facing: facing)
                )
                .scaleEffect(model.depthScale(facing: facing) * cam)
                .rotation3DEffect(
                    .degrees(-Double(slot.world)),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.5
                )
                .opacity(model.facingOpacity(facing: facing))
                .position(x: x - panelMinX, y: layerHeight / 2 + model.tiltDrop(facing: facing))
                .zIndex(Double(100 - abs(slot.world)))
                .accessibilityLabel("播放：\(track.title)")
            }
        }
        .frame(width: panel.halfWidth * 2, height: layerHeight)
        .clipShape(RoundedRectangle(cornerRadius: LiziTokens.radius22))
        .rotation3DEffect(
            .degrees(-5),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.5
        )
        .position(x: panel.centerX, y: cy)
    }
}

/// 环里的一张卡：封面 + 歌名 + 歌手（壳版 .mring__card：封面下只写歌名；
/// 视频里歌名下还有歌手，加一行；压暗只盖封面，文字保持可读）。
///
/// r22c：文字左对齐——8 张截图里每张环卡的歌名/歌手都从卡片左缘起
/// （r21 的居中与截图不符；壳版 `.mring__name` 也是默认左对齐）。
private struct RingCardView: View {
    let track: Track
    let width: CGFloat
    let shadeOpacity: Double

    /// r30：没封面（coverURL 为 nil）不摆白卡——深色默认封面（见 FlatRingCard
    /// coverArt 注释；URL 有但加载失败的白占位在 CoverImageView.swift 里）。
    @ViewBuilder
    private var coverArt: some View {
        if track.coverURL == nil {
            DefaultCoverArt(iconSize: 48)
        } else {
            CoverImageView(url: track.coverURL, placeholderIconSize: 48)
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
                        .fill(Color.black.opacity(shadeOpacity))
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
    /// 顶栏底边（r26-3D：命中测试与 ringLayer 用同一个 ringCenterY；
    /// HomeRingOverlayView 按横竖屏传 64/95，与 ringLayer 同值）。
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
            }
        default:
            break
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
