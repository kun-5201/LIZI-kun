import SwiftUI
import UIKit
import WebKit
import AVFoundation
import AVKit
import MediaPlayer

/// WKWebView 壳：启动 Swift 本地服务，加载 http://127.0.0.1:<port>/（1:1 的 liziair 前端）。
/// 后台播放：AVAudioSession .playback + audio 后台模式；锁屏/控制中心用
/// MPNowPlayingInfoCenter 显示当前曲目（读 document.title + #btn-play 状态）。

struct ContentView: View {
    @StateObject private var host = WebHost()
    /// 岛上 AirPlay 点过来（lizi://airplay）时弹出系统路由选择页。
    @State private var showAirPlayPicker = false

    var body: some View {
        ZStack {
            WebViewRepresentable(host: host)
                .ignoresSafeArea()
            if host.failed {
                VStack(spacing: 12) {
                    Text("本地服务启动失败")
                        .font(.headline)
                    Text(host.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("重试") { host.start() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            }
        }
        .onAppear { host.start() }
        .onOpenURL { url in
            guard url.scheme == "lizi" else { return }
            switch url.host {
            case "now":
                // 点岛胶囊 → 打开 App，落到正在播放的那首歌的播放页（按上次的形态进）。
                host.openNowPage()
            case "airplay":
                // 点岛上 AirPlay → 打开 App 并直接弹出系统路由选择页。
                // 岛上原地弹系统面板没有公开 API（见 LiziIslandIntents.swift），
                // 所以是“打开 App → 路由选择页 → 再点一下按钮出系统菜单”。
                showAirPlayPicker = true
            default:
                break
            }
        }
        .sheet(isPresented: $showAirPlayPicker) {
            AirPlayPickerSheet()
        }
    }
}

// MARK: - WebView 宿主

final class WebHost: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    private var server: LocalHttpServer?
    private var router = LiziRouter()
    let webView: WKWebView
    /// 歌词灵动岛：网页播放状态 → Live Activity。
    private let islandCoordinator = LiziIslandCoordinator()
    /// 本地音乐导入：前端 liziNative.postMessage({type:'importLocal'}) → 文件选择器。
    private let localBridge = LocalFilesBridge()
    /// QQ 网页登录：前端 liziQQLogin.postMessage({type:'qqWebLogin'}) → 弹 y.qq.com。
    private let qqWebLoginBridge = QQWebLoginBridge()
    /// 本地服务端口（QQ 网页登录 Sheet 同步时要 POST 回来）。
    private var serverPort: Int = 18791
    @Published var failed = false
    @Published var errorMessage = ""

    private var nowPlayingTimer: Timer?
    private var lastTitle = ""
    /// 锁屏 Now Playing 的上次写入值（artwork 到货时用它们重写一次，不用等下一轮轮询）。
    private var lastPlaying = false
    /// 音频会话是否已激活过（第 13 轮第 1 件：启动时只设 category 不激活，
    /// 第一次真正播放时才激活，避免打开 App 就抢走别的 App 的声音）。
    private var audioSessionActivated = false
    private var lastElapsed: Double = 0
    private var lastDuration: Double = 0
    private var lastNowPlayingWrite: Date = .distantPast
    /// 动画插图开关（设置页「外观」分区，localStorage['lizi.animatedArtwork']，
    /// 缺省 / '1' = 开，'0' = 关；默认开）。每轮 pollNowPlaying 从 localStorage 重读，
    /// 设置页刚改完下一轮就生效，不用等重启、不用走原生桥。
    private var animatedArtworkEnabled = true
    /// 锁屏专辑图（全屏铺满那张）：切歌时按封面 URL 重下，系统按需取尺寸。
    /// 没封面的歌时 lastCoverURL 是 "__default__"（哨兵，不是真 URL），
    /// 动态视频用 AnimatedArtworkManager.defaultKey。
    private var lastCoverURL: String?
    /// 当前歌的动态视频键（封面 URL 的 hash，没封面时是 defaultKey）。
    /// 动态视频没就绪时 writeNowPlayingInfo 用它查 fallback（上一首的缓存）。
    private var lastCoverKey: String?
    private var lastArtwork: MPMediaItemArtwork?
    private var fetchingArtworkURL: String?
    /// 封面下载失败记录（60 秒内不再重复拉同一条死链，直接上默认图）。
    private var failedCover: (url: String, at: Date)?
    /// 岛上点按跳回 App 的待办（lizi://now）：页面还没加载完时先记下来，
    /// 下一轮 pollNowPlaying 再试一次。
    private var pendingNowPage = false

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // 播放由用户手势触发；页面内 <audio> 走本机代理，同源没有 CORS 问题。
        config.mediaTypesRequiringUserActionForPlayback = []
        // 歌词灵动岛桥：注入 JS 每秒把播放状态 postMessage 到原生端。
        config.userContentController.add(islandCoordinator.bridge, name: "liziBridge")
        // 本地音乐导入桥：前端点「导入本地音乐」时 postMessage 到原生端弹文件选择器。
        config.userContentController.add(localBridge, name: "liziNative")
        // QQ 网页登录桥：前端点「网页登录」时 postMessage 到原生端弹 y.qq.com。
        config.userContentController.add(qqWebLoginBridge, name: "liziQQLogin")
        let islandScript = WKUserScript(source: LiziIslandJS.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(islandScript)
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.scrollView.bounces = false
        super.init()
        // 导入桥要拿 webView 发导入完成事件（弱引用，不成环）。
        self.localBridge.webView = self.webView
        // 网页登录桥：同步成功后要通知前端刷新登录态；端口启动后才知道。
        self.qqWebLoginBridge.webView = self.webView
        self.qqWebLoginBridge.portProvider = { [weak self] in self?.serverPort ?? 18791 }
        // 第 13 轮第 9 件：岛的封面走本机 /api/img 代理，端口跟 QQ 登录桥同一路。
        self.islandCoordinator.serverPortProvider = { [weak self] in self?.serverPort ?? 18791 }
        // 岛上控制按钮（LiveActivityIntent，不打开 App）：中继收到动作后
        // 点页面里的播放控制按钮 / 切喜欢态。App 播着歌时页面一定在；
        // 星标切完回读结果写回 likeCommand，锁屏卡片的星标跟着变。
        IslandControlRelay.shared.handler = { [weak self] action in
            guard let self else { return false }
            DispatchQueue.main.async {
                switch action {
                case .previous: self.clickButton("btn-prev")
                case .togglePlay: self.clickButton("btn-play")
                case .next: self.clickButton("btn-next")
                case .toggleLike:
                    self.webView.evaluateJavaScript("window.__liziLikeCurrent ? !!window.__liziLikeCurrent() : false") { result, _ in
                        if let liked = result as? Bool {
                            MPRemoteCommandCenter.shared().likeCommand.isActive = liked
                        }
                    }
                }
            }
            return true
        }
        // window.open（设置页 QQ 群 / 赞助行）交给系统浏览器/对应 App 打开；
        // 不设 uiDelegate 时 WKWebView 会直接丢弃新窗口请求，按钮点了没反应。
        self.webView.uiDelegate = self
        // 第 14 轮：内容进程被杀也要有人接（下面 webViewWebContentProcessDidTerminate）。
        self.webView.navigationDelegate = self
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return nil
    }

    // MARK: - WKNavigationDelegate

    /// 内容进程被系统杀掉（Jetsam/内存）时页面白屏、App 本身还在：记一笔面包屑
    /// 再重载页面，免得用户只看到白屏、还以为 App 闪退了，下次诊断里也能看到
    /// 这一步。60 秒内最多重载 3 次，防页面本身有问题时无限循环。
    private var contentReloads: [Date] = []

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        contentReloads = contentReloads.filter { now.timeIntervalSince($0) < 60 }
        guard contentReloads.count < 3 else { return }
        contentReloads.append(now)
        DiagLog.shared.recordPlaybackStep("webcontent terminated, reloading page")
        webView.reload()
    }

    func start() {
        // 幂等：onAppear 可能多次触发；重复启动会建一个新端口的服务、丢掉
        // 旧服务，页面还指着旧端口，后续 /api 请求全变 Load failed。
        // 但上次启动失败过（failed）时要允许重试：先停掉旧服务再建新的。
        if failed { server?.stop(); server = nil }
        guard server == nil else { return }
        failed = false
        // 第 14 轮第 20 件：锁屏命令注册不许依赖本地服务——以前它在 do 块里，
        // server 起失败就跳过注册，锁屏回落到系统默认的 ±10 秒快退快进。
        // 现在先注册命令再起服务（只点 DOM 按钮，服务没起时点按是空操作）。
        setupRemoteCommands()
        do {
            let server = try LocalHttpServer(router: router)
            self.server = server
            server.start()
            // 等 listener 就绪拿到端口再加载页面：冷启动时 0.5 秒未必够，
            // 每 250ms 查一次、最多 3 秒，拿不到才报失败。
            waitForPort(deadline: Date().addingTimeInterval(3))
            configureAudioSession()
            setupAudioInterruptions()
            startNowPlayingPolling()
        } catch {
            fail("启动本地服务失败：\(error.localizedDescription)")
        }
    }

    /// 轮询等端口（listener 就绪才有 port），拿到就加载页面。
    private func waitForPort(deadline: Date) {
        if let server, server.port > 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.load(port: server.port)
            }
            return
        }
        guard Date() < deadline else {
            fail("本地服务没有拿到端口")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForPort(deadline: deadline)
        }
    }

    private func fail(_ msg: String) {
        errorMessage = msg
        failed = true
    }

    private func load(port: Int) {
        serverPort = port
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
    }

    // MARK: - 后台播放

    /// 音频会话（第 13 轮第 1 件重写）：
    ///  - 独占 .playback，不带 .mixWithOthers：带 mix 时别的音乐 App 开播
    ///    不会中断 Lizi，两边会混着一起响——用户要的是“对方播、Lizi 停”，
    ///    只能独占，靠下面的 .began 通知来停。
    ///  - 启动时只设 category、不激活：激活会抢走别的 App 正在播的声音
    ///    （打开 Lizi 看一眼就把播客掐了）。会话在第一次真正播放时激活
    ///    （pollNowPlaying 见 playing 就激活），中断结束 / 回前台时按
    ///    lastPlaying 再激活一次。WKWebView 播媒体时系统自己也会激活会话，
    ///    这里只是补一道，不依赖它。
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            // 音频会话配不上也不拦着进页面；后台播放会受影响。
        }
    }

    /// 第 13 轮第 1 件：中断 .began 之前完全没接——别的音乐 App 一抢，
    /// 元素被系统暂停、state.playing 被置 false，但没有任何一方记下“被抢
    /// 前在播”，.ended 那个无条件 resume 也就没东西可续，只能死停。
    /// 现在三路分开：
    ///  - .began：只记（调页面 __liziAudioInterruptionBegan 记 wantResume），
    ///    不动元素、不抢会话；
    ///  - .ended：重新激活 + 调 __liziAudioInterruptionEnded，页面自己按
    ///    “还在前台才续、还在后台等回来再续”决定；
    ///  - didBecomeActive：只在上次在播时才重新激活（不播时不抢别人的声音），
    ///    再调页面 resume（后台影子接回 deck 在这里发生）；
    ///  - didEnterBackground：visibilitychange 是主路，这个是备用触发，
    ///    让页面把影子接管做掉（enterBackground 自己幂等）。
    private func setupAudioInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.webView.evaluateJavaScript("window.__liziAudioInterruptionBegan && window.__liziAudioInterruptionBegan()")
            case .ended:
                self.reactivateAudioSession()
                self.webView.evaluateJavaScript("window.__liziAudioInterruptionEnded && window.__liziAudioInterruptionEnded()")
            @unknown default:
                break
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reactivateAudioSession()
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.webView.evaluateJavaScript("window.__liziEnterBackground && window.__liziEnterBackground()")
        }
    }

    private func reactivateAudioSession() {
        // 只在上次在播时才激活：没播时激活会抢走别的 App 的声音。
        // 中断结束那路 lastPlaying 一定是 true（被抢前在播），不受影响。
        if lastPlaying {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                // 激活失败也不拦着；页面侧的 resume 仍会尝试。
            }
        }
        webView.evaluateJavaScript("window.__liziResumeWebAudio && window.__liziResumeWebAudio()")
    }

    // MARK: - 锁屏 / 控制中心

    // 第 14 轮第 20 件：锁屏/系统岛必须显示 上一首 | 暂停/播放 | 下一首，
    // 绝不能是 ±10 秒快退快进。真机 r13 包两张截图（14:32 锁屏、岛展开）都是
    // ±10 秒，而当前源码里根本没有 skipBackward/skipForward——说明真机跑的
    // 包没反映这份源码（或注册被跳过），iOS 26 在 previous/next 未启用时
    // 回落到默认的 ±10 秒按钮。所以这里三件事缺一不可：
    //  1) 快进快退显式关死（removeTarget + isEnabled=false），哪怕别的链路
    //     曾经把它打开过；2) 上一首/下一首/播放/暂停显式打开，不只靠
    //     addTarget 隐式启用；3) 幂等——start() 失败重试会再进这里，重复
    //     addTarget 会让一次按键触发两次（上一首连跳两首）。
    private var remoteCommandsSetup = false
    /// 上次记远程命令诊断的时间（第 15 轮第 2 件）：复核每 2 秒跑一次，
    /// 诊断只在状态与预期不符、首次、或距上次记满 60 秒时记一条，免得刷屏。
    private var lastRemoteCommandDiagAt: Date = .distantPast

    /// 第 15 轮第 2 件重写：去掉一次性注册限制，改为每轮 pollNowPlaying
    /// 复核一次（reassertRemoteCommands）。根因判断：播放开始后 WebKit
    /// 会按网页媒体会话重建 Now Playing 与命令（页面没设 MediaSession
    /// handler → 无上一首/下一首 → 回落 ±10 秒）；一次注册拦不住重建，
    /// 只能每轮把命令的启用/禁用状态重新断言回来。
    /// 每次都先 removeTarget 再 addTarget：重复 addTarget 会让一次按键触发多次。
    private func setupRemoteCommands() {
        reassertRemoteCommands()
    }

    private func reassertRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipBackwardCommand.removeTarget(nil)
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.removeTarget(nil)
        center.skipForwardCommand.isEnabled = false
        center.playCommand.removeTarget(nil)
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-play"); return .success
        }
        center.pauseCommand.removeTarget(nil)
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-play"); return .success
        }
        center.nextTrackCommand.removeTarget(nil)
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-next"); return .success
        }
        center.previousTrackCommand.removeTarget(nil)
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-prev"); return .success
        }
        center.togglePlayPauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.clickButton("btn-play"); return .success
        }
        // 喜欢（第 12 轮第 15 件补）：锁屏全屏卡片控制行的星标。
        // 系统只在 likeCommand 启用时才在锁屏/控制中心画星标；isActive 控制实心/空心。
        // 点星标 → 切当前曲目的喜欢态（player.js 的 __liziLikeCurrent），回读结果写回 isActive。
        center.likeCommand.removeTarget(nil)
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "喜欢"
        center.likeCommand.addTarget { [weak self] _ in
            self?.webView.evaluateJavaScript("window.__liziLikeCurrent ? !!window.__liziLikeCurrent() : false") { result, _ in
                if let liked = result as? Bool {
                    MPRemoteCommandCenter.shared().likeCommand.isActive = liked
                }
            }
            return .success
        }
        remoteCommandsSetup = true
        // 复核后记一条诊断（各命令实际启用状态）：状态与预期不符、首次、
        // 或距上次记满 60 秒时才记。下次真机报告能证明命令到底开没开，
        // 而不是只凭截图猜。
        let states = "play=\(center.playCommand.isEnabled) pause=\(center.pauseCommand.isEnabled) next=\(center.nextTrackCommand.isEnabled) prev=\(center.previousTrackCommand.isEnabled) skipBwd=\(center.skipBackwardCommand.isEnabled) skipFwd=\(center.skipForwardCommand.isEnabled) like=\(center.likeCommand.isEnabled)"
        let mismatch = !center.playCommand.isEnabled || !center.pauseCommand.isEnabled
            || !center.nextTrackCommand.isEnabled || !center.previousTrackCommand.isEnabled
            || center.skipBackwardCommand.isEnabled || center.skipForwardCommand.isEnabled
        let now = Date()
        if mismatch || lastRemoteCommandDiagAt == .distantPast
            || now.timeIntervalSince(lastRemoteCommandDiagAt) >= 60 {
            lastRemoteCommandDiagAt = now
            DiagLog.shared.recordLog(category: "remote-commands",
                message: "remote commands reasserted: \(states)\(mismatch ? " MISMATCH" : "")",
                fields: ["reason": mismatch ? "remote-commands-mismatch" : "remote-commands-ok", "lane": "remote-commands"])
        }
    }

    private func clickButton(_ id: String) {
        webView.evaluateJavaScript("document.getElementById('\(id)')?.click()")
    }

    /// 岛上点按跳回 App（lizi://now）：落到正在播放的那首歌的播放页，
    /// 按上次的形态进（舞台/经典，见 app.js enterNowPage）。
    /// 页面还没加载完时记下来，等下一轮 pollNowPlaying 再试一次。
    func openNowPage() {
        webView.evaluateJavaScript("window.__liziEnterNowPage ? (window.__liziEnterNowPage(), true) : false") { [weak self] result, _ in
            if (result as? Bool) != true { self?.pendingNowPage = true }
        }
    }

    /// 每 2 秒读一次 document.title（app.js 切歌时会写成“歌名 · 歌手”），
    /// 以及 #btn-play 的状态，更新锁屏 Now Playing。不做歌词岛。
    private func startNowPlayingPolling() {
        nowPlayingTimer?.invalidate()
        nowPlayingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollNowPlaying()
        }
    }

    /// 每 2 秒读一次 document.title（app.js 切歌时会写成“歌名 · 歌手”），
    /// 以及 #btn-play 的状态、播放进度、封面、喜欢态，更新锁屏 Now Playing。
    /// 锁屏全屏铺满是系统行为：系统拿这里供的 artwork 画全屏背景 + 磨砂卡片，
    /// App 不自己画锁屏（第 12 轮第 15/16 件）。
    private func pollNowPlaying() {
        let js = """
        (() => {
          const title = document.title || '';
          const btn = document.getElementById('btn-play');
          const cls = btn ? btn.className : '';
          const label = btn ? (btn.getAttribute('aria-label') || '') : '';
          let cover = null, cur = 0, dur = 0, liked = false;
          try {
            if (typeof Player !== 'undefined' && Player && Player.audio) {
              cur = Player.audio.currentTime || 0;
              dur = Player.audio.duration || 0;
              const q = Player.state.queue || [];
              const t = q[Player.state.index];
              if (t && t.cover) cover = String(t.cover);
            }
            if (typeof window.__liziLiked === 'function') liked = !!window.__liziLiked();
          } catch (e) {}
          if (!cover) {
            const img = document.getElementById('np-cover');
            if (img && img.src) cover = img.src;
          }
          // 动画插图开关（设置页「外观」分区，localStorage['lizi.animatedArtwork']，
          // 缺省 / '1' = 开，'0' = 关）。原生端每轮都读：关着不生成视频、不挂 animated 键。
          let animatedArtwork = true;
          try { animatedArtwork = localStorage.getItem('lizi.animatedArtwork') !== '0'; } catch (e) {}
          return JSON.stringify({ title, cls, label, cover, cur, dur, liked, animatedArtwork });
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            // 岛上点按跳回 App 的待办：页面好了就补执行一次。
            if pendingNowPage {
                pendingNowPage = false
                openNowPage()
            }
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = obj["title"] as? String, !title.isEmpty,
                  title != "LIZI · 粒子播放器" else { return }
            // 第 15 轮第 2 件：每轮复核一次远程命令（WebKit 播起来后会按网页
            // 媒体会话重建 Now Playing，一次注册拦不住重建）。
            reassertRemoteCommands()
            // 歌名 · 歌手（app.js 切歌时写的格式）
            let parts = title.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let track = parts.first ?? title
            let artist = parts.count > 1 ? parts[1] : ""
            let cls = obj["cls"] as? String ?? ""
            let label = obj["label"] as? String ?? ""
            // 按钮上是“暂停”含义时正在播放；认不出时默认按播放中显示。
            let playing = label.contains("暂停") || cls.contains("playing") || cls.contains("pause")
                || (!label.contains("播放") && !cls.contains("paused"))
            let elapsed = (obj["cur"] as? Double) ?? 0
            let duration = (obj["dur"] as? Double) ?? 0
            let liked = (obj["liked"] as? Bool) ?? false
            // 星标实心/空心跟着当前曲目的喜欢态走。
            MPRemoteCommandCenter.shared().likeCommand.isActive = liked
            // 动画插图开关：每轮都从 localStorage 读（设置页刚改完，下一轮就生效）。
            // 关 → 下面同一轮的 writeNowPlayingInfo 就不挂 animated 键，锁屏回静态；
            // 开（刚从关切回来）→ 当前歌还没生成过视频的话立刻为它生成，别等到下一首。
            let animatedOn = (obj["animatedArtwork"] as? Bool) ?? true
            if animatedOn != animatedArtworkEnabled {
                animatedArtworkEnabled = animatedOn
                if animatedOn {
                    if lastCoverURL == "__default__" {
                        prepareAnimatedArtwork(cover: Self.defaultCoverImage(),
                                               key: AnimatedArtworkManager.defaultKey, coverURL: "__default__")
                    } else if let raw = lastCoverURL {
                        fetchLockScreenArtwork(raw)
                    }
                }
            }
            // 封面换了就重下（高清，供锁屏铺满），到了再补写一次 Now Playing。
            // 没封面的歌不留上一首的图：上默认图（深色底 + ♪），动态视频也按默认图生成，
            // 每首歌锁屏上都动起来（第 12 轮第 20 件 03:33 硬性要求）。
            let coverURL = (obj["cover"] as? String) ?? ""
            let normalizedCoverURL = coverURL.isEmpty ? "__default__" : coverURL
            if normalizedCoverURL != (lastCoverURL ?? "") {
                if coverURL.isEmpty {
                    applyDefaultLockScreenCover()
                } else if let failed = failedCover, failed.url == coverURL,
                          Date().timeIntervalSince(failed.at) < 60 {
                    // 这条封面 60 秒内刚拉失败过：别重复拉死链，直接上默认图。
                    applyDefaultLockScreenCover()
                } else {
                    lastCoverURL = coverURL
                    fetchLockScreenArtwork(coverURL)
                }
            }
            // 第 14 轮第 11 件：JS 快照停了（切后台被节流）时，原生喂岛。
            // 只在播放中喂；暂停时不喂，让 staleDate 按设计清掉岛。
            // 放在 Now Playing 的 guard 之前：岛的存活不依赖锁屏那次写操作。
            if playing, Date().timeIntervalSince(islandCoordinator.lastJSSnapshotAt) > 3 {
                islandCoordinator.receiveNative(
                    title: track, artist: artist, isPlaying: true,
                    currentTime: elapsed, duration: duration,
                    coverURL: coverURL.isEmpty ? nil : coverURL, isLiked: liked)
            }
            // 切歌 / 播放暂停切换 / 时长变了就重写；播着时每 2 秒刷新一次进度，
            // 锁屏卡片里的进度条才跟得上（系统不会自己一直往前推）。
            let durationChanged = abs(duration - lastDuration) > 0.5
            let stale = playing && Date().timeIntervalSince(lastNowPlayingWrite) >= 2.0
            guard title != lastTitle || playing != lastPlaying || durationChanged || stale else { return }
            lastTitle = title
            lastPlaying = playing
            // 第 13 轮第 1 件：第一次真正播放时才激活音频会话（启动时只设了
            // category、不激活，避免打开 App 就抢走别的 App 的声音）。
            // 之后靠中断结束 / 回前台的 reactivateAudioSession 维持。
            if playing && !audioSessionActivated {
                audioSessionActivated = true
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                } catch { /* 激活失败也不拦着；媒体播放时系统自己也会激活 */ }
            }
            lastElapsed = elapsed
            lastDuration = duration
            writeNowPlayingInfo(title: track, artist: artist)
        }
    }

    /// 按上次读到的值写一次 Now Playing（artwork 到货时也走这里补写）。
    private func writeNowPlayingInfo(title: String, artist: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyPlaybackRate: lastPlaying ? 1.0 : 0.0,
        ]
        if !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
        if lastDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = lastDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = lastElapsed
        }
        if let art = lastArtwork { info[MPMediaItemPropertyArtwork] = art }
        // 第 12 轮第 20 件：iOS 26+ 动态封面。开关关着时整个跳过，锁屏保持静态图。
        // 只挂 supportedAnimatedArtworkKeys 里在列的键；本歌视频没就绪
        // （还在渲染/渲染失败）就挂上一首的缓存，不要静默变回静态。
        // 第一首歌、又没任何缓存时不挂（那几秒只能先静态，等 onReady 回调补写）。
        // 26 以下这段整个跳过。
        if #available(iOS 26.0, *),
           animatedArtworkEnabled,
           let animKey = animatedArtworkKeyForCurrentTrack() {
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork),
               let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .portrait) {
                info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
            }
            if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork),
               let art = AnimatedArtworkManager.shared.artwork(forKey: animKey, aspect: .square) {
                info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingWrite = Date()
    }

    /// 当前歌挂哪个动态视频：本歌的视频就绪就挂本歌的；没就绪（还在渲染/渲染失败）
    /// 就挂上一首的缓存——不要静默变回静态（第 20 件 03:33 硬性要求）。
    /// 第一首歌、又没任何缓存时返回 nil（那几秒只能先静态，等 onReady 回调补写）。
    private func animatedArtworkKeyForCurrentTrack() -> String? {
        if let key = lastCoverKey, AnimatedArtworkManager.shared.isReady(key: key) { return key }
        return AnimatedArtworkManager.shared.fallbackKey(for: lastCoverKey ?? "")
    }

    /// 锁屏专辑图：先走 https 下整张原图（各家封面 CDN 都支持），
    /// 最长边压到 1000px 再交给系统（全屏铺满要大图，但 3000px 原图没必要）。
    /// 下不到就上默认图（别留着上一首的图——那是另一首歌的封面）。
    /// 锁屏封面（第 13 轮第 9 件重写）：先走本机 /api/img 代理，再走直链。
    /// 相对地址（#np-cover 兜底的 /api/img?url=...）拼成本机绝对地址再拉；
    /// 直链 http 升 https（日志 07:05:50：直链 http 被 ATS -1022 秒拦）。
    private func fetchLockScreenArtwork(_ raw: String) {
        guard fetchingArtworkURL != raw else { return }
        var urls: [URL] = []
        if raw.hasPrefix("/") {
            if let u = URL(string: "http://127.0.0.1:\(serverPort)\(raw)") { urls.append(u) }
            // 第 15 轮第 1 件：相对地址常是 /api/img?url=<原地址>；原来只有
            // 代理一路，代理 403 即死。把原地址解出来再直连一次（http 升 https）。
            if let comps = URLComponents(string: raw),
               let orig = comps.queryItems?.first(where: { $0.name == "url" })?.value,
               let rawURL = URL(string: orig),
               rawURL.scheme == "http" || rawURL.scheme == "https",
               var dcomps = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
                if dcomps.scheme == "http" { dcomps.scheme = "https" }
                if let direct = dcomps.url { urls.append(direct) }
            }
        } else if let rawURL = URL(string: raw),
                  rawURL.scheme == "http" || rawURL.scheme == "https" {
            var comps = URLComponents(string: "http://127.0.0.1:\(serverPort)/api/img")
            comps?.queryItems = [URLQueryItem(name: "url", value: raw)]
            if let proxy = comps?.url { urls.append(proxy) }
            if var dcomps = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
                if dcomps.scheme == "http" { dcomps.scheme = "https" }
                if let direct = dcomps.url { urls.append(direct) }
            }
        }
        guard !urls.isEmpty else { return }
        fetchingArtworkURL = raw
        fetchLockScreenArtworkFrom(urls, at: 0, raw: raw)
    }

    /// 按候选顺序拉锁屏封面：非 2xx / 坏数据就试下一路，都死透才记失败+上默认图。
    /// 第 15 轮第 1 件：每一步记 DiagLog（lane + host + 状态），下次真机报告
    /// 能区分“代理 403 → 直链也死”还是“直链根本没跑”。
    private func fetchLockScreenArtworkFrom(_ urls: [URL], at index: Int, raw: String) {
        guard index < urls.count else {
            fetchingArtworkURL = nil
            // 封面拉不到（CDN 挂了、URL 坏了）：记一笔，60 秒内不再重复拉这条死链，
            // 直接上默认图（默认图的动态视频也照常生成，每首歌都动）。
            failedCover = (url: raw, at: Date())
            DiagLog.shared.recordLog(category: "cover",
                message: "lock cover all lanes failed, using default: \(raw.prefix(80))",
                fields: ["reason": "lock-cover-all-failed", "lane": "lockscreen"])
            applyDefaultLockScreenCover()
            return
        }
        let lane = urls[index].host == "127.0.0.1" ? "proxy" : "direct"
        URLSession.shared.dataTask(with: urls[index]) { [weak self] data, resp, _ in
            guard let self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                // 歌已经切走了：这张旧图别再往锁屏上写，新歌那轮轮询会自己拉。
                guard self.lastCoverURL == raw else { self.fetchingArtworkURL = nil; return }
                let okStatus = (200..<300).contains(status)
                guard okStatus, let data, let image = UIImage(data: data) else {
                    DiagLog.shared.recordLog(category: "cover",
                        message: "lock cover lane=\(lane) failed host=\(urls[index].host ?? "") status=\(status)",
                        fields: ["host": urls[index].host ?? "", "reason": "lock-cover-lane-failed", "code": status, "lane": "lockscreen"])
                    self.fetchLockScreenArtworkFrom(urls, at: index + 1, raw: raw)
                    return
                }
                DiagLog.shared.recordLog(category: "cover",
                    message: "lock cover ok lane=\(lane) host=\(urls[index].host ?? "")",
                    fields: ["host": urls[index].host ?? "", "reason": "lock-cover-ok", "lane": "lockscreen"])
                self.fetchingArtworkURL = nil
                self.lastCoverKey = AnimatedArtworkManager.key(forCoverURL: raw)
                let sized = Self.lockScreenSized(image)
                self.lastArtwork = MPMediaItemArtwork(boundsSize: sized.size) { _ in sized }
                // 第 12 轮第 20 件：iOS 26+ 锁屏动态封面（路线 A：本地渲染）。
                // 静态图先写进去兜底；动态视频好了再补写一次（同 artworkID，系统认作同一张封面）。
                self.prepareAnimatedArtwork(cover: image, key: AnimatedArtworkManager.key(forCoverURL: raw), coverURL: raw)
                // 图到了：按上次的曲目信息补写一次，锁屏立刻换图。
                guard !self.lastTitle.isEmpty else { return }
                let parts = self.lastTitle.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                self.writeNowPlayingInfo(title: parts.first ?? self.lastTitle, artist: parts.count > 1 ? parts[1] : "")
            }
        }.resume()
    }

    /// 没封面的歌（JS 没给 cover，或封面下载失败）：上默认图，别留着上一首的图。
    /// 默认图也有动态视频（按默认图生成，所有没封面的歌共用一份），
    /// 每首歌锁屏上都动起来（第 12 轮第 20 件 03:33 硬性要求）。
    /// 已在默认图上时直接返回，不重复做。
    private func applyDefaultLockScreenCover() {
        guard lastCoverURL != "__default__" else { return }
        lastCoverURL = "__default__"
        lastCoverKey = AnimatedArtworkManager.defaultKey
        let image = Self.defaultCoverImage()
        let sized = Self.lockScreenSized(image)
        lastArtwork = MPMediaItemArtwork(boundsSize: sized.size) { _ in sized }
        prepareAnimatedArtwork(cover: image, key: AnimatedArtworkManager.defaultKey, coverURL: "__default__")
    }

    /// 动态视频准备（iOS 26+ 且「动画插图」开关开着才跑）。视频好了补写一次 Now Playing。
    /// 开关关着时不生成、不挂键，锁屏保持静态图；渲染中途关掉，回调里也不写。
    private func prepareAnimatedArtwork(cover image: UIImage, key: String, coverURL: String) {
        guard animatedArtworkEnabled else { return }
        if #available(iOS 26.0, *) {
            AnimatedArtworkManager.shared.prepare(cover: image, key: key) { [weak self] in
                guard let self, self.animatedArtworkEnabled, self.lastCoverURL == coverURL,
                      !self.lastTitle.isEmpty else { return }
                let parts = self.lastTitle.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                self.writeNowPlayingInfo(title: parts.first ?? self.lastTitle, artist: parts.count > 1 ? parts[1] : "")
            }
        }
    }

    /// 默认封面：程序化画一张深色渐变底 + ♪，不用额外带资源文件。
    /// 只画一次，后面复用同一张。
    private static let defaultCover: UIImage = {
        let size = CGSize(width: 1000, height: 1000)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let top = UIColor(red: 0.14, green: 0.14, blue: 0.24, alpha: 1).cgColor
            let bottom = UIColor(red: 0.04, green: 0.04, blue: 0.09, alpha: 1).cgColor
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [top, bottom] as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: 0, y: size.height), options: [])
            let note = NSAttributedString(string: "♪", attributes: [
                .font: UIFont.systemFont(ofSize: 420),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ])
            let nsSize = note.size()
            note.draw(at: CGPoint(x: (size.width - nsSize.width) / 2,
                                  y: (size.height - nsSize.height) / 2))
        }
    }()

    private static func defaultCoverImage() -> UIImage { defaultCover }

    private static func lockScreenSized(_ image: UIImage) -> UIImage {
        let maxEdge: CGFloat = 1000
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let scale = maxEdge / longest
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: target))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
}

struct WebViewRepresentable: UIViewRepresentable {
    let host: WebHost

    func makeUIView(context: Context) -> WKWebView {
        host.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - AirPlay 路由选择页

/// 岛上 AirPlay 点过来时弹出的页：系统路由选择器（AVRoutePickerView）。
/// 点这个按钮出系统设备列表 + 音量条——就是用户要的“系统自带那个 AirPlay 音量面板”。
/// 第三方 Live Activity 里放不了这个视图，也没有 API 能在岛上原地弹面板，
/// 所以是“打开 App → 这个页 → 再点一下按钮出系统菜单”，比截图里 Apple Music
/// 的原地弹出多一次点击；平台限制，汇报里写清。
struct AirPlayPickerSheet: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("选择音频输出设备，点下面按钮弹出系统菜单，可切设备、调音量。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                AirPlayPickerView()
                    .frame(width: 44, height: 44)
                Spacer()
            }
            .padding()
            .navigationTitle("音频输出")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// AVRoutePickerView 的 SwiftUI 包装（UIKit 视图，只能在 App 内用，扩展里放不了）。
struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
