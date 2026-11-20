import Combine
import Foundation
import SwiftUI
import UIKit
import WebKit

/// 舞台 Web 承载桥（P3-A）：形态页继续用 WKWebView 承载，HUD 全部原生。
///
/// 对照壳版 `public/app.js` 的 `StageHost` + `StagePanel`，协议一字不改：
/// - 宿主 → 形态：`postMessage({ __c100: 1, type, payload })`，类型 `init` /
///   `tick` / `beat` / `live` / `setting` / `panel`。形态只读 `e.data`，
///   不校验 origin / source，所以原生侧用 `evaluateJavaScript` 派发一个合成
///   `MessageEvent('message')` 就能送达（形态脚本在解析期就挂好监听器了）。
/// - 形态 → 宿主：形态调 `parent.postMessage({ __c100: 1, type, payload })`。
///   原生侧形态文档本身就是顶层 frame（`parent === window`），`postMessage`
///   发给自己会触发本窗口的 `message` 事件；注入的 user script（文档开始时
///   运行）监听它，只把形态真正外发的四种类型（`ready` / `activity` /
///   `key` / `error`）经 `webkit.messageHandlers.liziStage` 转给原生。
///   宿主自己派发的合成事件也会经过这条监听器，按类型过滤掉，不回环。
/// - 加载：`loadFileURL` + 读权限给到 `Resources/` 根目录。形态文件在
///   `Resources/stages/*.html`，相对引用 `assets/...` 走 `stages/assets/`；
///   只有 304-kidcore 引用 `../assets/fonts/...`，字体也按同样相对布局
///   拷进了 `Resources/assets/fonts/`。不用 `public/` 拷贝，不用
///   LocalHttpServer，不用自定义 scheme。
///   集成（P3 r19 去重）：`stages/`（全小写）是全包唯一一份形态文件；
///   画廊那份 `GalleryHTML/stages/` 已删，长廊页的 stage-layer 改走
///   `../../stages/...`（见 forms-labs/js/app.js stageSrc）。
///
/// 播放状态一律读 `PlaybackStore`（不另建状态机）：切歌 / 行变 / 播放切换
/// 订阅 store 的发布值；锁屏走 NowPlayingCoordinator（MPNowPlayingInfoCenter
/// 系统卡），本桥不碰锁屏；r28 已移除灵动岛。
///
/// 第 16 轮教训：本文件全程无强制解包（`as!` / `try!` / `!` 解包一律不用）；
/// 取不到值就退化（默认重音色 / 空歌词 / 不发消息），绝不在播放启动路径上炸掉。
final class StageBridge: NSObject, ObservableObject {

    // MARK: - 发布状态（StageView 读这些画 HUD）

    /// 当前形态。
    @Published private(set) var currentForm: StageForm
    /// 形态发过一次 ready（init 已下发）。
    @Published private(set) var isReady = false
    /// 相机形态（ready payload 里 `camera: true`；552 烟雨江南唯一一个）：
    /// 只有两处特殊：不盖 SwiftUI 点屏唤醒层（会吃掉拖动手势，改走 webView
    /// 上的轻点识别器，见 StageWebViewCoordinator），形态内活动不唤醒 HUD。
    /// r31：相机形态不再有任何别的特殊——胶囊不再默认收起、「显示控制」
    /// 药丸已删（用户 06:18），控制行与唤醒方式与其它形态一致。
    @Published private(set) var isCamera = false
    /// 当前形态声明的设置面板（`window.__stagePanel`；r31 起 85 个已收录形态
    /// 全有声明，359 在 r31 补了 shake 面板，此前是唯一没有的）。
    @Published private(set) var panelSpec: StagePanelSpec?
    /// HUD 是否可见（壳版 `stage-hud` 的 `is-idle` 反状态：2.6 秒无操作自动藏起）。
    @Published private(set) var hudVisible = true

    /// 宿主收到形态的空格键（焦点在形态文档里时父页面收不到，只能由形态转发）。
    var onSpaceKey: (() -> Void)?

    /// HUD 闲置计时挂起（选择器 / 设置面板打开时不自动藏 HUD）。
    var hudSuspended = false

    // MARK: - 内部

    private weak var store: PlaybackStore?
    private weak var webView: WKWebView?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTimer: Timer?
    private var tickCount = 0
    private var hudTimer: Timer?
    private var lastInteraction = Date()
    private var readyFallback: DispatchWorkItem?
    private var lastInitSig = ""
    private var accent: [Int] = [150, 165, 255]
    private var accentTrackId: String?
    private var lastLyricIndex = -1
    private var lastTrackKey = ""
    private var settings: [String: StagePanelValue] = [:]

    /// 注入脚本名（与 `webkit.messageHandlers` 同名，`liziStage`）。
    static let messageHandlerName = "liziStage"

    /// 转发脚本：只转发形态外发的四种类型；宿主合成事件（init/tick/beat/live/
    /// setting/panel）直接忽略，不回环。形态的 `parent.postMessage` 在顶层
    /// frame 里就是发给自己，`message` 事件照常派发，这条监听器收得到。
    static let forwardScript = """
        window.addEventListener('message', function (e) {
          var d = e.data;
          if (!d || d.__c100 !== 1) return;
          var t = d.type;
          if (t !== 'ready' && t !== 'activity' && t !== 'key' && t !== 'error') return;
          try {
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liziStage;
            if (h) h.postMessage({ type: t, payload: d.payload || null });
          } catch (_) {}
        }, false);
        """

    init(initialFormId: String? = nil) {
        let saved = initialFormId ?? StageCatalog.savedFormId()
        if let form = StageCatalog.form(id: saved), StageCatalog.isAvailable(form) {
            currentForm = form
        } else if let first = StageCatalog.form(id: StageCatalog.defaultFormId) {
            currentForm = first
        } else {
            currentForm = StageCatalog.all.first ?? StageForm(
                formId: "001", name: "粒子歌词", desc: "", fileName: nil, isCamera: false)
        }
        super.init()
        loadSettings()
    }

    // MARK: - 接线

    /// StageView.onAppear 时把 PlaybackStore 接进来（StateObject 创建时还拿不到
    /// environmentObject，所以分两步；重复调是幂等的）。
    func attach(store: PlaybackStore) {
        guard self.store == nil else { return }
        self.store = store
        wakeHUD()
        startHudTimer()
        // r22l 编译修：PlaybackStore 是 @MainActor（第 22 轮第 5 件，
        // 代际计数器设计靠它，不许摘），它的 @Published 发布者
        // $currentTrack / $currentLyricIndex / $isPlaying 也是主隔离，
        // 非隔离的 attach 里同步订阅报硬错。本方法只在 StageView.onAppear
        // 里调（主线程），订阅三句包进 MainActor.assumeIsolated；
        // 不改 attach 签名（改 @MainActor 会把错挪到 StageView 的
        // onAppear 闭包里），不改订阅行为与回调。
        MainActor.assumeIsolated {
            store.$currentTrack
                .sink { [weak self] track in
                    guard let self else { return }
                    Task { @MainActor in self.onTrackChanged(track) }
                }
                .store(in: &self.cancellables)
            store.$currentLyricIndex
                .sink { [weak self] idx in
                    guard let self else { return }
                    Task { @MainActor in self.onLyricIndexChanged(idx) }
                }
                .store(in: &self.cancellables)
            store.$isPlaying
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in self.pushInit(force: false) }
                }
                .store(in: &self.cancellables)
            store.$lyrics
                .sink { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in self.pushInit(force: false) }
                }
                .store(in: &self.cancellables)
        }
    }

    /// StageView.onDisappear 时停掉 tick（壳版 leave() 还会卸掉 iframe；
    /// 原生侧切出舞台页视图即销毁，webView 随之释放，这里只停计时器）。
    func detach() {
        stopTick()
        stopHudTimer()
        readyFallback?.cancel()
        readyFallback = nil
    }

    // MARK: - HUD 闲置（壳版 armIdle / wake：2.6 秒无操作藏起）

    /// 任何 HUD 操作 / 形态内活动都调这个：HUD 露出来，闲置计时重算。
    func wakeHUD() {
        hudVisible = true
        lastInteraction = Date()
    }

    func startHudTimer() {
        stopHudTimer()
        lastInteraction = Date()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.hudVisible, !self.hudSuspended,
               Date().timeIntervalSince(self.lastInteraction) > 2.6 {
                self.hudVisible = false
            }
        }
    }

    private func stopHudTimer() {
        hudTimer?.invalidate()
        hudTimer = nil
    }

    // MARK: - 形态切换

    /// 切形态（选择器 / 形态名点选都走这里；classic 由 StageView 直接回播放页，不进桥）。
    func load(form: StageForm) {
        guard StageCatalog.isAvailable(form) else { return }
        currentForm = form
        StageCatalog.saveFormId(form.formId)
        isReady = false
        isCamera = form.isCamera
        panelSpec = nil
        lastInitSig = ""
        lastLyricIndex = -1
        loadSettings()
        loadCurrentFile()
    }

    /// 当前形态文件的 bundle URL（file://；读权限给 Resources/ 根）。
    static func fileURL(for form: StageForm) -> URL? {
        guard let fileName = form.fileName else { return nil }
        return Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "stages")
    }

    /// `loadFileURL` 的读权限根目录（`Resources/`，含 `stages/` 与 `assets/`）。
    static func readAccessURL() -> URL? {
        guard let stagesURL = Bundle.main.url(forResource: "001-particle-lyrics", withExtension: "html", subdirectory: "stages") else { return nil }
        return stagesURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func loadCurrentFile() {
        guard let webView, let url = Self.fileURL(for: currentForm) else { return }
        let readAccess = Self.readAccessURL() ?? url.deletingLastPathComponent()
        webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        // 兜底：个别形态可能不发 ready（壳版只认 ready 才发 init，会一直空白）；
        // 2 秒后仍没 ready 就直接发一次 init（监听器在解析期已挂好，不会丢）。
        armReadyFallback()
    }

    /// 2 秒兜底（r22a：loadCurrentFile 里调；播放页隐藏 webView 已随顶栏纠正撤下）。
    /// 个别形态不发 ready 时，2 秒后直接取 panelSpec + 发 init + 推全部设置，不一直空白。
    /// 只在 webView 已挂好且尚未 ready 时生效；重复调会取消上一次。
    func armReadyFallback() {
        guard webView != nil, !isReady else { return }
        readyFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isReady {
                self.isReady = true
                self.fetchPanelSpec()
                self.pushInit(force: true)
                // r31：设置重推不在这里调——fetchPanelSpec 是异步的，此时
                // panelSpec 还是 nil，调了也直接 return（见 fetchPanelSpec
                // 里的完成回调，那里 spec 已到才推）。
            }
        }
        readyFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - 形态 → 宿主（message handler 回调）

    func handleStageMessage(type: String, payload: [String: Any]?) {
        switch type {
        case "ready":
            onReady(payload: payload)
        case "activity":
            // 壳版 onActivity：相机形态在触屏上拖动不唤醒 HUD，其余活动都 wake()。
            if !isCamera { wakeHUD() }
        case "key":
            if let key = payload?["key"] as? String, key == "Space" {
                wakeHUD()
                onSpaceKey?()
            }
        default:
            // 'error' 形态外发也经 forwardScript 转来，但桥上没有任何读者
            // （r31 删掉了只写不读的 lastError），直接忽略，不回环。
            break
        }
    }

    private func onReady(payload: [String: Any]?) {
        // 只认第一次 ready（壳版同款去重：有的形态每次收到 init 都回一次 ready，
        // 再 pushInit(true) 会 ping-pong，一秒几千次 init，tick 发不出去）。
        if isReady { return }
        if let camera = payload?["camera"] as? Bool {
            isCamera = camera
        }
        isReady = true
        readyFallback?.cancel()
        fetchPanelSpec()
        pushInit(force: true)
        // r31：设置重推不在这里调——fetchPanelSpec 是异步的，此时 panelSpec
        // 还是 nil，调了也直接 return（切形态/重进后已存的调节全丢、形态按
        // JS 默认值画，就是这次修的 bug；重推在 fetchPanelSpec 完成回调里）。
        startTick()
    }

    // MARK: - 宿主 → 形态

    /// 发一条 `__c100` 消息给形态（合成 MessageEvent；payload 经 base64 走，
    /// 歌词里的引号 / 换行 / U+2028 都不会把 JS 字符串截断）。
    func post(type: String, payload: [String: Any]) {
        guard let webView else { return }
        let envelope: [String: Any] = ["__c100": 1, "type": type, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: []),
              !data.isEmpty else { return }
        let b64 = data.base64EncodedString()
        let js = "window.dispatchEvent(new MessageEvent('message',{data:JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(b64)'),function(c){return c.charCodeAt(0)})))}));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 歌词时间轴（壳版 `lyricSchedule`）：LRC 只有起点，这里补每句时长
    /// （下一句起点 = 本句结束；末句 6 秒）；YRC 逐字时间照原样带过去。
    /// 形态歌词三档（壳版 `stageLyricMode`，键 `lizi.stage.lyricMode`，
    /// 默认 `orig`，见 `SettingsStore`）：`orig` 照原样；`trans` 有译文
    /// 用译文、没有译文的行照旧原文；`both` 同排拼成「原文 ｜ 译文」。
    /// 译文与原文字数不一样、逐字时间戳对不上，`trans`/`both` 一律不带
    /// chars，让形态按句长自己均分（壳版 `lyricSchedule` 同款做法）。
    private func lyricSchedule() -> [[String: Any]] {
        guard let store else { return [] }
        // r22l 编译修：store.lyrics 是 @MainActor 隔离的发布状态，
        // 非隔离方法里同步读报硬错；本方法只在 pushInit 里调，
        // pushInit 的调用链全在主线程（见下），包进 assumeIsolated。
        let lines = MainActor.assumeIsolated { store.lyrics }
        let mode = SettingsStore.readStageLyricMode()
        return lines.enumerated().map { (i, line) in
            let start = Double(line.startMs) / 1000
            let next = (i + 1 < lines.count) ? Double(lines[i + 1].startMs) / 1000 : nil
            let dur: Double
            if let next {
                dur = max(0.4, next - start)
            } else {
                dur = 6
            }
            var chars: [[String: Any]] = []
            for w in line.words {
                chars.append(["c": w.text, "t": Double(w.startMs) / 1000])
            }
            var text = line.text
            if !line.translation.isEmpty {
                if mode == "trans" {
                    text = line.translation
                    chars = []
                } else if mode == "both" {
                    text = line.text + " ｜ " + line.translation
                    chars = []
                }
            }
            var row: [String: Any] = [
                "t": start,
                "dur": dur,
                "text": text,
            ]
            if !chars.isEmpty { row["chars"] = chars }
            return row
        }
    }

    /// init 下发（壳版 `pushInit` 的签名去重：同一首歌 + 同一份歌词 + 同一个
    /// 重音色不重复发，免得形态每收到一次就清粒子重组）。
    ///
    /// r22l 编译修：store.currentTrack / .lyrics / .duration 都是
    /// @MainActor 隔离的发布状态（PlaybackStore 第 22 轮第 5 件，
    /// 不许摘），非隔离的 pushInit 里同步读报硬错。调用链全在主线程：
    /// attach 的 sink（Task @MainActor）、onReady（message handler 的
    /// Task @MainActor）、ready 兜底（DispatchQueue.main）、
    /// updateAccent 完成回调（Task @MainActor）——所以三处读都包进
    /// MainActor.assumeIsolated；不改签名（改 @MainActor 会把错挪到
    /// armReadyFallback 的 DispatchWorkItem 等调用点），不改去重签名与内容。
    func pushInit(force: Bool) {
        guard let store else { return }
        let track = MainActor.assumeIsolated { store.currentTrack }
        let lines = MainActor.assumeIsolated { store.lyrics }
        let duration = MainActor.assumeIsolated { store.duration }
        let sigParts: [String] = [
            track?.id ?? "",
            String(lines.count),
            lines.first.map { String($0.startMs) } ?? "0",
            lines.last.map { String($0.startMs) } ?? "0",
            lines.first.map { String($0.words.count) } ?? "0",
            accent.map(String.init).joined(separator: ","),
            // r25 #31：形态歌词档也进签名——切档后歌词文本变了，签名不变
            // 会被去重挡掉、形态收不到新词（壳版切档调 StageHost.refresh()
            // 强制重发；原生侧这里靠签名变化触发重发）。
            SettingsStore.readStageLyricMode(),
        ]
        let sig = sigParts.joined(separator: "|")
        if !force, sig == lastInitSig { return }
        lastInitSig = sig
        let song: [String: Any] = [
            "id": track?.id ?? "",
            "name": track?.title ?? "",
            "album": track?.album ?? "",
            "artists": track?.artist ?? "",
            "cover": track?.coverURL?.absoluteString ?? "",
        ]
        post(type: "init", payload: [
            "song": song,
            "accent": accent,
            "lines": lyricSchedule(),
            "duration": duration,
        ])
    }

    /// 66ms tick（壳版 `startTick` 同款 cadence）：当前进度 + 是否在播。
    /// 歌词延迟（壳版 F5 面板 `lyric-delay.js`）原生版没有对应设置，固定 0。
    private func startTick() {
        stopTick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.066, repeats: true) { [weak self] _ in
            guard let self, let store = self.store else { return }
            // r22l 编译修：store.progress / .isPlaying 是 @MainActor 隔离的
            // 发布状态；定时器建在主线程、跑在主 runloop 上，回调一定在主线
            // 程，整段包进 MainActor.assumeIsolated（日志只报了 live 那行
            // 的 isPlaying，但 tick 那行的 progress / isPlaying 是同一访
            // 问模式，一并包进来，免得换个 SDK 又冒出来）。
            MainActor.assumeIsolated {
                self.post(type: "tick", payload: [
                    "time": store.progress,
                    "playing": store.isPlaying,
                ])
                self.tickCount += 1
                // live 约 8Hz（壳版 120ms 节流）：原生版没有音频分析器，
                // bpm / 频段全 0，只同步 playing；形态靠 tick + 歌词行推进。
                if self.tickCount % 8 == 0 {
                    self.post(type: "live", payload: [
                        "bpm": 0,
                        "level": 0,
                        "bass": 0,
                        "mid": 0,
                        "treble": 0,
                        "playing": store.isPlaying,
                    ])
                }
            }
        }
    }

    private func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        tickCount = 0
    }

    // MARK: - 播放状态变化

    private func onTrackChanged(_ track: Track?) {
        let key = (track?.platform ?? "") + "|" + (track?.id ?? "")
        if key != lastTrackKey {
            lastTrackKey = key
            lastInitSig = ""
            updateAccent(for: track)
        }
        pushInit(force: false)
    }

    private func onLyricIndexChanged(_ idx: Int) {
        guard idx != lastLyricIndex else { return }
        lastLyricIndex = idx
        // 壳版 beat 来自音频分析；原生版没有分析器，行变时给一拍 level 1
        //（播放中才有；震动开关关了则 level 恒 0，见 shakeOff 注释）。
        // r22l 编译修：store.isPlaying 是 @MainActor 隔离的发布状态，
        // 非隔离方法里同步读报硬错（`!=` 的 autoclosure 里报的）；
        // 本方法只在 attach 的 sink 里经 Task @MainActor 调，
        // 包进 MainActor.assumeIsolated。
        let level: Int = MainActor.assumeIsolated {
            (self.shakeOff() || self.store?.isPlaying != true) ? 0 : 1
        }
        post(type: "beat", payload: ["index": idx, "level": level])
    }

    /// 震动总闸（壳版 `shakeOff`）：形态设置里 `shake` 关掉后 beat.level 恒 0，
    /// 形态的抖动/脉冲都是 beat.level 乘出来的，归零等于从根上停震。
    private func shakeOff() -> Bool {
        if let v = settings["shake"], case .bool(let b) = v { return !b }
        return false
    }

    /// 封面主色（壳版 `accentRgb`）：取封面图下采样后的平均色；取不到（无封面 /
    /// 下载失败 / 解码失败）就用壳版默认 `[150, 165, 255]`，绝不用金色。
    private func updateAccent(for track: Track?) {
        guard let url = track?.coverURL, let trackId = track?.id else {
            accent = [150, 165, 255]
            accentTrackId = nil
            return
        }
        if accentTrackId == trackId { return }
        accentTrackId = trackId
        // r24：走 Proxies.directImageData——同一个门、6s 上限、入口 https 归一；
        // 旧写法 dataTask 直连原地址：http 在真机上 ATS -1022，https 无超时
        // 上限（默认 60s），主色一直算不出来。
        Task { [weak self] in
            guard let self else { return }
            guard let data = await Proxies.directImageData(url),
                  let image = UIImage(data: data),
                  let rgb = Self.averageColor(of: image) else { return }
            await MainActor.run {
                guard self.accentTrackId == trackId else { return }
                self.accent = rgb
                self.pushInit(force: false)
            }
        }
    }

    private static func averageColor(of image: UIImage) -> [Int]? {
        // 显式 RGBA8 上下文：1x1 下采样后的唯一像素就是整图的平均色，
        // 通道顺序由 bitmapInfo 定死，不依赖 UIGraphics 上下文的默认格式。
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
    }

    // MARK: - 形态设置面板（壳版 StagePanel）

    private static func settingsKey(for formId: String) -> String {
        "lizi.native.stageSettings." + formId
    }

    private func loadSettings() {
        settings = [:]
        let key = Self.settingsKey(for: currentForm.formId)
        guard let raw = UserDefaults.standard.string(forKey: key),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: StagePanelValue].self, from: data) else { return }
        settings = dict
        // r31：之前这里用 JSONSerialization + `v as? Bool` 先判 Bool——NSNumber
        // 会桥接成 Bool（非零数都判成 true、0 判成 false），存过的滑杆值（如
        // camSpeed 2.2）重进/切形态回来全被读成 true/false，滑杆跳到 1.0/0.0。
        // JSONDecoder 按 JSON 类型解码（true/false 只认真布尔，数字只认数字），
        // StagePanelValue 的 Decodable 顺序（Bool → Double → String）与之配套。
    }

    private func saveSettings() {
        var dict: [String: Any] = [:]
        for (k, v) in settings {
            switch v {
            case .bool(let b): dict[k] = b
            case .number(let n): dict[k] = n
            case .string(let s): dict[k] = s
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: Self.settingsKey(for: currentForm.formId))
    }

    /// 面板控件当前值（没存过就用声明的默认值）。
    func settingValue(for item: StagePanelItem) -> StagePanelValue {
        if let v = settings[item.key] { return v }
        return item.def ?? .string("")
    }

    /// 改一个设置：写盘 + 发 `setting` 给形态（壳版 `StagePanel.push` 同款）。
    func setSetting(key: String, value: StagePanelValue) {
        settings[key] = value
        saveSettings()
        post(type: "setting", payload: ["key": key, "value": value.jsonValue])
    }

    /// 恢复默认：清掉本形态的存值并按声明默认值全量重推（壳版 `spnl-reset`）。
    func resetSettings() {
        settings = [:]
        UserDefaults.standard.removeObject(forKey: Self.settingsKey(for: currentForm.formId))
        pushAllSettings()
    }

    /// ready 后把当前全部设置推一遍（壳版 `pushAll`）。
    func pushAllSettings() {
        guard let spec = panelSpec else { return }
        for item in spec.items {
            let v = settingValue(for: item)
            post(type: "setting", payload: ["key": item.key, "value": v.jsonValue])
        }
    }

    /// 读形态声明的 `window.__stagePanel`（壳版直接读 `contentWindow.__stagePanel`；
    /// 原生侧用 `evaluateJavaScript` 序列化后解码；读不到 = 该形态没声明面板）。
    ///
    /// r31：全量重推（pushAllSettings）只能在这里调——evaluateJavaScript 是
    /// 异步的，spec 只有进了这个完成回调才真正到手。之前 onReady /
    /// armReadyFallback 里 fetch 后立刻 pushAllSettings()，那时 panelSpec
    /// 还是 nil，全量重推直接 return：切形态 / 重进舞台后，已存的调节一次
    /// 也没发给新文档，形态全按 JS 默认值画，用户调过的值"丢了"（直到再
    /// 动一次控件才单条补发）。现在 spec 一到就推，形态一 ready 就拿到
    /// 全部已存值；resetSettings() 的重推不受影响（那时 spec 已在）。
    func fetchPanelSpec() {
        guard let webView else { return }
        webView.evaluateJavaScript("JSON.stringify(window.__stagePanel || null)") { [weak self] result, _ in
            guard let self else { return }
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let spec = try? JSONDecoder().decode(StagePanelSpec.self, from: data) else {
                Task { @MainActor in self.panelSpec = nil }
                return
            }
            Task { @MainActor in
                self.panelSpec = spec
                self.pushAllSettings()
            }
        }
    }
}

// MARK: - message handler（单转发，不持有 webView，避免循环引用）

final class StageMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: StageBridge?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == StageBridge.messageHandlerName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let payload = body["payload"] as? [String: Any]
        Task { @MainActor in
            self.bridge?.handleStageMessage(type: type, payload: payload)
        }
    }
}

// MARK: - 面板声明模型（`window.__stagePanel` 的 JSON 形状）

struct StagePanelSpec: Decodable {
    var title: String?
    var hint: String?
    var items: [StagePanelItem]
}

struct StagePanelItem: Decodable, Identifiable {
    var id: String { key }
    var key: String
    var label: String?
    /// range / switch / select / segment（壳版 StagePanel.render 的四种）。
    var type: String
    var min: Double?
    var max: Double?
    var step: Double?
    var def: StagePanelValue?
    var options: [StagePanelOption]?
}

struct StagePanelOption: Decodable {
    var v: String
    var t: String
}

/// 面板值：数字 / 开关 / 文本三态（JSON 里 `def` 可能是其中任意一种）。
enum StagePanelValue: Decodable, Equatable {
    case number(Double)
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .string("") }
    }

    var jsonValue: Any {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b
        case .string(let s): return s
        }
    }

    var doubleValue: Double {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .string(let s): return Double(s) ?? 0
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" || s == "1"
        }
    }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

// MARK: - WKWebView 承载（UIViewRepresentable）

struct StageWebView: UIViewRepresentable {
    @ObservedObject var bridge: StageBridge

    func makeCoordinator() -> StageWebViewCoordinator {
        StageWebViewCoordinator(bridge: bridge)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 形态文档用 file:// 加载；`allowsInlineMediaPlayback` + 空白媒体策略
        // 对应壳版 iframe 的 `allow="autoplay"`。
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let script = WKUserScript(
            source: StageBridge.forwardScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        config.userContentController.add(context.coordinator.handler, name: StageBridge.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = true
        webView.backgroundColor = .black
        context.coordinator.attach(webView: webView)
        if let url = StageBridge.fileURL(for: bridge.currentForm) {
            let readAccess = StageBridge.readAccessURL() ?? url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 形态切换由桥的 load(form:) 触发（r31：删掉了这里原来写的
        // coordinator.loadIfNeeded——那个方法从来不存在，是写死的旧引用）；
        // 这里只做兜底：webView 空着（首次 / 切形态后）就按当前形态装一次。
        if uiView.url == nil, let url = StageBridge.fileURL(for: bridge.currentForm) {
            let readAccess = StageBridge.readAccessURL() ?? url.deletingLastPathComponent()
            uiView.loadFileURL(url, allowingReadAccessTo: readAccess)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: StageWebViewCoordinator) {
        coordinator.detach(webView: uiView)
    }
}

/// 导航代理 + message handler 持有者（桥本身不直接当 handler，避免
/// `userContentController` 强引用 handler 造成循环引用）。
///
/// r31：还管点屏唤醒的轻点识别器（见 attach）。SwiftUI 的全屏透明唤醒层
/// 不能盖在相机形态（552）上——会吃掉拖动手势；原来相机形态只剩底部
/// 「显示控制」药丸唤回，药丸 r31 已删（用户 06:18），唤醒统一改走这个
/// recognizer：只认轻点（`cancelsTouchesInView = false` + 同时识别），
/// 拖动、滚动照常进形态，相机转头不受影响。非相机形态的轻点本来就被
/// SwiftUI 唤醒层截获，不会走到这里；HUD 已显示时轻点只重置闲置计时。
final class StageWebViewCoordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
    let handler = StageMessageHandler()
    private weak var bridge: StageBridge?
    private weak var webView: WKWebView?
    private var tapRecognizer: UITapGestureRecognizer?

    init(bridge: StageBridge) {
        self.bridge = bridge
        super.init()
        handler.bridge = bridge
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        bridge?.setWebView(webView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleStageTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        tapRecognizer = tap
    }

    func detach(webView: WKWebView) {
        if let tap = tapRecognizer {
            webView.removeGestureRecognizer(tap)
            tapRecognizer = nil
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: StageBridge.messageHandlerName)
        webView.navigationDelegate = nil
        bridge?.setWebView(nil)
    }

    @objc private func handleStageTap() {
        bridge?.wakeHUD()
    }

    /// 与 WKWebView 内部手势同时识别：本识别器只认轻点，拖动/滚动不抢，
    /// 形态收到的触摸原样不动。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        // 文档换了：之前 `load(form:)` 的新文档已就绪；ready 由形态自己发，
        // 桥的 2 秒兜底只在没 ready 时补发 init（见 StageBridge.loadCurrentFile）。
    }
}

extension StageBridge {
    /// 供 coordinator 绑定 / 解绑 webView（load(form:) 通过它换文档）。
    fileprivate func setWebView(_ webView: WKWebView?) {
        self.webView = webView
        if webView != nil {
            startTickIfNeeded()
        }
    }

    private func startTickIfNeeded() {
        // 进入舞台即开始 tick（壳版 enter() 调 startTick；ready 后再调一次是幂等的）。
        if tickTimer == nil {
            startTick()
        }
    }
}
