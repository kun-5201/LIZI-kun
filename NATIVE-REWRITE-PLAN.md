# Lizi 全原生 1:1 重写 · 总体方案

> 决定：2026-11-19，用户亲口定——把 Lizi 从 WKWebView 套壳改成真正的原生 App，SwiftUI 前端，一比一对照安卓版。壳版最后一包是第 16 轮（commit 2ece0270，run 44533829189）；壳版源码原样保留在 `~/workspace/lizi-ios/`，不要删、不要破坏它的构建。用户仓库 kun-5201/liziair 远端仍在 aab3d17，绝不推；构建走公开仓库 kun-5201/lizi-build-tmp。

## 0. 摸底结论（2026-11-19，三路工人）

- **安卓版也是套壳，不是原生 UI**：极薄自研壳 + WebView + 内嵌 Node.js（`libnode.so` 跑 `server.mjs`），WebView 加载 `http://127.0.0.1:<port>/m/`。所以「按安卓版 1:1 复刻」的意思是：按它呈现出来的样子与操作，用 SwiftUI 原生重做，不再套网页。详见 `~/workspace/lizi-android-ref/unpacked/ANALYSIS-REPORT.md`。
- **安卓快照比 iOS 旧**（约 11 月 9 日，无 Apple Music，`app.js` 791KB vs iOS 866KB）：**以 iOS 壳版为准，安卓只作结构/布局参照**。
- **壳版 Swift 后端约 1.6 万行基本可复用**，但播放本身不在 Swift 里——音频是 WebView 内 `<audio>`、状态机/队列/歌词解析全在 JS，原生层要从零建播放核心。
- 屏幕清单来源：工人 B 报告（`public/` 逐页盘点：12 整页视图 + 6 类浮层）与工人 A 报告（APK：13 屏）已合并且去重，见 §1。

## 1. 屏幕清单（1:1 目标）

| # | 屏幕 | 视图 | 阶段 | 备注 |
|---|---|---|---|---|
| 1 | 首页/大厅 | hall | P1 | Hero 大卡、平台条、每日推荐跑马带、来源滚轮、我的喜欢/收藏/电台、本地音乐区 |
| 2 | 搜索与搜索结果 | browse | P1 | 顶栏搜索框、音源切换条、曲目列表、搜索历史 |
| 3 | 播放页 | now | P1 | 3D 封面流、大封面、歌名/歌手、传输排、3 行歌词预览 + 完整歌词面板、队列、抽屉、dock |
| 4 | 灵动岛 / 锁屏 | Live Activity + Now Playing | P1 | 复用现有扩展与锁屏链路（见 §3） |
| 5 | 歌单详情 | browse 复用 | P2 | 与搜索结果共用列表组件与队列 |
| 6 | 歌手页 / 专辑页 | artist / album | P2 | 热门 Top 10、专辑网格、全部歌曲 |
| 7 | 我的专辑（3D 陈列架） | myalbums | P2 | spine 侧立 / flow 正面两种形态，本地收藏 |
| 8 | 精选 / 我的喜欢 / 收藏歌单 / 电台 | hall rails | P2 | 各平台自己的接口（见 §4 规则） |
| 9 | 舞台页 | stage | P3 | HUD 原生化；673 个形态继续 WKWebView 承载 `stages/*.html`，不逐个原生化 |
| 10 | 形态长廊 / 球面画廊 | forms / stage-pick | P3 | 球面画廊纯 UI 可原生；预览 iframe 同舞台处理 |
| 11 | 设置页 | settings | P3 | 7 分区：平台账号、LX 源管理、本地音乐、音效、播放页排版、外观、关于 |
| 12 | 登录全流程 | modal + 各平台行 | P4 | 二维码 / 网页登录 / Cookie 粘贴 / Apple Music token |
| 13 | 本地音乐 | hall-local | P4 | 文件导入 + 列表 + 开关 |
| 14 | 音效页（EQ） | audio | P4 | 9 档音质 + 10 套预设 + 7 段 EQ（AVAudioUnitEQ） |
| 15 | 工具箱（歌单搬运 / 空间音频） | tools | P5 | 搬运可原生化；空间音频评估 AVAudioEngine 方案 |
| 16 | 音乐实验室（DJ 台） | lab | P5 | 重型，排最后或只做简化版 |
| — | 开场引导 tour | overlay | 砍掉 | 已隐藏入口，不复刻 |

不在范围：`public/_ab/`、`_fx/`、`lab/`、`forms-labs/`（除画廊本体）、`settings-lab/`、`player-skins/` 等实验/废弃目录；`.bak` 历史备份不照搬。

## 2. 后端复用清单（Swift 侧，不重写）

共享底座：`SessionStore`（会话/Cookie）、`Crypto`（网易 weapi/eapi）、`Upstream`（上游请求）、`Proxies`（图片/音频代理 + 白名单，含 r15 的 `.mzstatic.com`）、`DiagLog`（诊断 + 播放面包屑）、`LocalFiles`（本地音乐）、`Sidecars` 分发。
六平台服务（各 `handle(req)` 今日是 HTTP 入口，内部 `search/songUrl/lyric` 多为 `private`——原生直调要加一层薄的类型化封装）：`NetEase.swift`、`QQ.swift`（actor）、`Qishui.swift`、`Bodian.swift`、`Kuwo.swift`、`AppleMusic.swift`（只有 30 秒试听，见 §5 缺口）。
登录：各平台二维码、QQ 网页登录（`QQWebLoginSheet.swift` 的 View 可复用）、Cookie 手动导入。
LX：`LXSources.swift` + `LXScriptEngine.swift`（JavaScriptCore，不依赖 WebKit，可原样复用）；`LX.swift` 的 sourceMap 与档位归一化。
歌词：`Lrclib.swift`（只认 syncedLyrics）；各平台 `lyric()` 只回 LRC/YRC 文本，行切分与逐字解析要新写。
动画插图：`AnimatedArtwork.swift`（Ken Burns 本地生成，可原样复用；开关改存 UserDefaults）。
岛/锁屏：`LiveActivityManager`、`LiziLyricsAttributes`、`LiziIslandIntents`（IslandControlRelay 结构保留，handler 改调原生播放器）、`MPRemoteCommandCenter` 注册逻辑、`AVAudioSession` 配置与中断处理。

可删的桥接（原生版不要）：`LocalHttpServer` + `LiziRouter` + `StaticFiles.serve` + `public/` 拷贝、WKUserScript 每秒读 DOM、LyricsBridge、`pollNowPlaying` 的 JS 部分、`clickButton(id:)`、`liziDiag` 桥、`liziNative` 桥、`WebHost` 整体。`Router.handleLxSongUrl` 的参数映射是协议文档，重构时对照着搬。

## 3. 工程布局决定

- 同一 `project.yml`、同一仓库，**新增 `LiziNative` app target + `LiziNativeLiveActivity` 扩展 target**；壳版 `Lizi` 与 `LiziLiveActivity` target 一行不改。
- 新代码全部进 `ios/Sources/LiziNative/`；新扩展视图进 `ios/Sources/LiziNativeLiveActivity/`。
- **第一阶段不搬文件**：新 target 的 `sources` 列 `Sources/LiziNative` + 逐个列出的共享文件（约 20 个，见工人 C 报告 §1 清单）。共享后端不靠「包含整个 `Sources/Lizi` 目录」（会把 WebHost 等编进去）。第二阶段再考虑抽 `Sources/LiziShared/`。
- **bundle ID 必须不同**：壳版 `com.lty5201.lizi`；原生 `com.lty5201.lizi-native`，扩展 `com.lty5201.lizi-native.LiziLiveActivity`，显示名开发期加后缀区分，两版可同装一台手机对照。URL scheme 分开：壳版 `lizi://`，原生 `lizinative://`（否则点岛会打开错 App）。
- **plist key 双保险照抄第 16 轮**：新 target 的 `settings.base` 写 `INFOPLIST_KEY_NSSupportsLiveActivities: "YES"` + FrequentUpdates，同时 `info.properties` 写 `NSSupportsLiveActivities: true` + FrequentUpdates。`UIBackgroundModes: [audio]` 只写 `info.properties`。不要手写 Info.plist 文件。workflow 断言照抄（PlistBuddy 读 `NSSupportsLiveActivities` 必须为 `true`）。
- **数据不共享**：无 App Group；SessionStore、UserDefaults、LX 脚本目录、Caches 各按 bundle ID 隔离。原生 App 首次启动是未登录态（登录态迁移是产品决策，本轮不做）。
- **Swift 5.0，不升 Swift 6**（服务端静态可变状态在严格并发下是硬错）；deploymentTarget iOS 16.2 不变。
- 构建：同一 workflow 加第二个 job（或 matrix），`-scheme LiziNative`、独立 archive 路径与 artifact 名 `lizi-native-ipa`；断言照抄（验 plist key + appex + bundle ID；不验 `public/`）。`build_public_repo.py` 的 commit message 目前写死「第 16 轮」，要参数化。原生版「关于 → 构建」另起生成步骤，不能复用 `public/version.json`（原生包里没有 `public/`）。
- 注意（P0 实测纠正）：XcodeGen 的 `info` 要求写 `path`——它不是读磁盘已有 plist，而是生成时把 properties 写到该路径（壳版 `Sources/Lizi/Info.plist` 磁盘上不存在也是同理，构建机上生成）。新 target 写 `Sources/LiziNative/Info.plist` 与 `Sources/LiziNativeLiveActivity/Info.plist`；不要手写 Info.plist 文件内容。

## 4. 必须带过去的产品规格（细读 ~/MEMORY.md Lizi 一节）

- 7 个平台同步实现、同步修、同步验；没有官方接口的平台不编假数据，老实写清没有。
- 音源优先级：平台官方 → 已登录个人云盘 → LX → 演示音；搜索只用各平台自己的接口、绝不用 LX 搜索。
- 岛上专辑目标：紧凑左封面右波形、展开 5 按钮（星标/上一首/暂停/下一首/AirPlay）、点胶囊进正在播放页、App 被杀岛立刻消失（同步 end + staleDate + 启动清理）。
- 锁屏专辑目标：系统锁屏供图、全屏背景 + 磨砂卡片（App 不自画锁屏）。
- 动态封面路线 A：每曲本地生成动态视频；「动画插图」开关默认开，关 = 锁屏回静态图。
- 首页滑动切歌：左滑上一首、右滑下一首、锁开关（默认解锁，持久化）；两张首页卡片可拖动调大小（无回弹、持久化）。
- 任何操作禁缩放、尺寸按设备分档固定；封面取专辑主色、没有封面用白色；九档音质，显示音质 = 实际返回档位。
- 第 16 轮教训：点播闪退的崩溃点在取到资源之后、播放启动那一段——原生版播放启动路径不要留强制解包，面包屑诊断（`DiagLog.recordPlaybackStep`，文件落盘）要带过去；LX「不限域名」假设只在本地服务绑 127.0.0.1 时成立，LX 返回的 URL 直接进 AVPlayer 前要重新定白名单策略。

## 5. 原生 UI 层缺口清单（要新写，按依赖顺序）

1. `PlaybackStore`（ObservableObject 播放状态机）+ 队列/`Track` 模型 + 循环模式。
2. 音频引擎：AVPlayer 封装（直链/代理链路选择、后台播放、中断处理、独占 `mixWithOthers`，双音频问题不回归）。
3. 取链编排器：fallback 顺序 + 9 档音质映射（显示实回档位）。
4. LRC 解析器 + 行模型 + 逐字 YRC 解析 + 当前行判定；歌词来源编排（官方 → LRCLIB → 无词显示歌名，绝不用 ♪ 作假）。
5. 搜索结果模型（分平台分组、分页）；推荐/歌单/电台/歌手/专辑模型；平台管理模型（7 平台登录态聚合 + Folia 式全功能：未登录点图标直接进公开内容）。
6. 二维码登录视图 + 轮询状态机；Cookie 导入视图；QQ 网页登录 sheet；Apple Music token 填写。
7. `SettingsStore`（UserDefaults 统一，逐项迁移 localStorage 键名）。
8. 全部 SwiftUI 视图（§1 清单）；手势与布局规则原生实现（滑动切歌、卡片拖拽、禁缩放、3D Cover Flow）。
9. 岛/锁屏接线：状态机 → `LiziIslandCoordinator.receive`；`IslandControlRelay.handler` 直调播放器；锁屏写入改 AVPlayer 时间观察者驱动。

## 6. 阶段计划（每阶段一个 IPA，单独交回、单独发版）

- **P0 脚手架**：布局落地（§3）+ 骨架 App（@main、空态首页）+ 构建链路打通 + 第一包验证（bundle ID、plist key、appex、未签名）。
- **P1 第一版能用**：首页 + 搜索 + 播放页 + 灵动岛/锁屏（含播放核心 §5-1~4）。驱动验证 + 独立验包后交回。
- **P2 内容页**：歌单详情、歌手/专辑、我的专辑、精选/喜欢/收藏/电台。
- **P3 舞台与设置**：舞台 HUD 原生化（形态继续 Web 承载）、形态长廊、设置页全分区。**Folia 舞台时序（用户 2026-11-20 00:08 定）**：LX 那批（落雪 + 喜欢 rail 改名 + 动态封面 bug + 路线 B）不做 Folia；做到 P3 舞台这一版时把 Folia 舞台全部加进去——先全量盘点（stage 组件、visualizer、StageModeRows、播放控制器，逐个列出），再逐个定搬法（Web 承载的走 WKWebView、能原生化的原生做，接进 P3-A 已有的舞台目录/选择器/HUD），AGPL-3.0 红线：照形态与流程自己重写实现，不要原样抄代码；驱动加一项逐个核对 Folia 舞台形态都在。
- **P4 登录与本地**：登录全流程、本地音乐、音效页。
- **P5 收尾**：工具箱、实验室（评估后定做不做/简化版）、动态封面全量、首页手势与卡片尺寸、全量回归。

## 7. 诚实边界

- Apple Music 整首播放无现成方案：`song/url` 只出 30 秒试听，需原生 MusicKit + 用户开发者账号；原生版第一版同样只能 30 秒试听，不编假功能。
- 舞台 626/673 个形态不原生化，继续 WKWebView 承载（与安卓策略一致）；DJ 台重型，排最后。
- 驱动验证在 VM 上做，真机渲染（岛/锁屏/封面/手势）只能用户真机确认；每阶段报告如实写清哪些只在 VM 静态验过。

## 8. 版本快照（长期规则，用户 2026-11-20 立）

源码一个版一个版本地保留好。每次交付新版，除了推编译仓库出包，还要多做一步：把当版完整源码树拷一份到 `~/workspace/lizi-ios-versions/<版名>/`（如 native-P3、r17），不要只留工作目录里那一份会被覆盖的。交回报告里写清本版快照路径。已交付的旧版（r14/r15/r16、原生 P0/P1/P2）由主代理从编译仓库提交里回拷归档，不在本规则的以后各版里重复做。
