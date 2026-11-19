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
/// 订阅 store 的发布值；岛 / 锁屏仍走 `NativeIslandCoordinator` 已有的订阅
/// 链路，本桥不碰 LiveActivity。
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
    /// HUD 切极简，迷你播放器默认收起。
    @Published private(set) var isCamera = false
    /// 当前形态声明的设置面板（`window.__stagePanel`；69 个已收录形态全有声明）。
    @Published private(set) var panelSpec: StagePanelSpec?
    /// 形态外发的最后一条 error（仅诊断展示用，不弹窗）。
    @Published private(set) var lastError: String?
    /// 形态里鼠标/触摸活动（供 HUD 闲置计时续命；相机形态触屏拖动不唤醒，见下）。
    @Published private(set) var activityTick = 0
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
        store.$currentTrack
            .sink { [weak self] track in
                guard let self else { return }
                Task { @MainActor in self.onTrackChanged(track) }
            }
            .store(in: &cancellables)
        store.$currentLyricIndex
            .sink { [weak self] idx in
                guard let self else { return }
                Task { @MainActor in self.onLyricIndexChanged(idx) }
            }
            .store(in: &cancellables)
        store.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.pushInit(force: false) }
            }
            .store(in: &cancellables)
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
        lastError = nil
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
        readyFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isReady {
                self.isReady = true
                self.fetchPanelSpec()
                self.pushInit(force: true)
                self.pushAllSettings()
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
            activityTick += 1
            if !isCamera { wakeHUD() }
        case "key":
            if let key = payload?["key"] as? String, key == "Space" {
                wakeHUD()
                onSpaceKey?()
            }
        case "error":
            if let p = payload {
                lastError = p["message"] as? String ?? p.description
            } else {
                lastError = "stage error"
            }
        default:
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
        pushAllSettings()
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
    private func lyricSchedule() -> [[String: Any]] {
        guard let store else { return [] }
        let lines = store.lyrics
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
            var row: [String: Any] = [
                "t": start,
                "dur": dur,
                "text": line.text,
            ]
            if !chars.isEmpty { row["chars"] = chars }
            return row
        }
    }

    /// init 下发（壳版 `pushInit` 的签名去重：同一首歌 + 同一份歌词 + 同一个
    /// 重音色不重复发，免得形态每收到一次就清粒子重组）。
    func pushInit(force: Bool) {
        guard let store else { return }
        let track = store.currentTrack
        let lines = store.lyrics
        let sigParts: [String] = [
            track?.id ?? "",
            String(lines.count),
            lines.first.map { String($0.startMs) } ?? "0",
            lines.last.map { String($0.startMs) } ?? "0",
            lines.first.map { String($0.words.count) } ?? "0",
            accent.map(String.init).joined(separator: ","),
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
            "duration": store.duration,
        ])
    }

    /// 66ms tick（壳版 `startTick` 同款 cadence）：当前进度 + 是否在播。
    /// 歌词延迟（壳版 F5 面板 `lyric-delay.js`）原生版没有对应设置，固定 0。
    private func startTick() {
        stopTick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.066, repeats: true) { [weak self] _ in
            guard let self, let store = self.store else { return }
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
        let level: Int = (shakeOff() || store?.isPlaying != true) ? 0 : 1
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
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data, let image = UIImage(data: data),
                  let rgb = Self.averageColor(of: image) else { return }
            Task { @MainActor in
                guard self.accentTrackId == trackId else { return }
                self.accent = rgb
                self.pushInit(force: false)
            }
        }.resume()
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
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return }
        for (k, v) in dict {
            if let b = v as? Bool { settings[k] = .bool(b) }
            else if let n = v as? NSNumber { settings[k] = .number(n.doubleValue) }
            else if let s = v as? String { settings[k] = .string(s) }
        }
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
            Task { @MainActor in self.panelSpec = spec }
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
        // 形态切换由桥的 load(form:) 触发（见 coordinator.loadIfNeeded）；
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
final class StageWebViewCoordinator: NSObject, WKNavigationDelegate {
    let handler = StageMessageHandler()
    private weak var bridge: StageBridge?
    private weak var webView: WKWebView?
    private var loadedFormId: String?

    init(bridge: StageBridge) {
        self.bridge = bridge
        super.init()
        handler.bridge = bridge
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        bridge?.setWebView(webView)
        loadedFormId = bridge?.currentForm.formId
    }

    func detach(webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: StageBridge.messageHandlerName)
        webView.navigationDelegate = nil
        bridge?.setWebView(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        // 文档换了：之前 `load(form:)` 的新文档已就绪；ready 由形态自己发，
        // 桥的 2 秒兜底只在没 ready 时补发 init（见 StageBridge.loadCurrentFile）。
        loadedFormId = bridge?.currentForm.formId
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
