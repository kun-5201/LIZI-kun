import Foundation
import UIKit
import WebKit

/// 歌词灵动岛桥接：网页播放器 → 原生 Live Activity。
///
/// 网页端（liziair 前端）自己已经有歌词（多源 LRC，含逐字），并渲染在
/// #lyrics 里（每行 `.ly`，当前行 `.ly.is-active`，正文在 `.ly__main` 里）。
/// 原生端不重新取词，只读 DOM 里已经算好的当前行 / 上一行 / 下一行 +
/// 播放进度，推灵动岛。这样歌词来源、断句、逐字高亮都和页面上显示的
/// 完全一致，也不用再走一遍网易接口。
///
/// 桥：注入一段 JS（WKUserScript，document end），每 1 秒把当前状态
/// postMessage 到 `liziBridge`；原生端 WKScriptMessageHandler 收到后
/// 交给 LiziIslandCoordinator，按行变 / 切歌 / 播放暂停切换立刻推，
/// 进度最多 5 秒推一次（Apple 的 Live Activity 更新预算）。

// MARK: - 注入的 JS

enum LiziIslandJS {
    /// 每 1 秒收集一次播放状态并 postMessage 到原生。
    /// 全部防御式写法：元素不存在 / Player 未加载时返回 null 字段，不抛错。
    static let script = """
    (function () {
      if (window.__liziIslandBridgeInstalled) return;
      window.__liziIslandBridgeInstalled = true;

      function getAudio() {
        try {
          if (typeof Player !== 'undefined' && Player && Player.audio) return Player.audio;
        } catch (e) {}
        var audios = document.querySelectorAll('audio');
        for (var i = 0; i < audios.length; i++) {
          if (!audios[i].paused) return audios[i];
        }
        for (var j = 0; j < audios.length; j++) {
          if (audios[j].src) return audios[j];
        }
        return audios[0] || null;
      }

      function lineText(el) {
        if (!el) return null;
        var main = el.querySelector('.ly__main');
        var t = (main ? main.textContent : el.textContent || '').trim();
        return t ? t : null;
      }

      function coverUrl() {
        try {
          if (typeof Player !== 'undefined' && Player && Player.state) {
            var q = Player.state.queue || [];
            var cur = q[Player.state.index];
            if (cur && cur.cover) return String(cur.cover);
          }
        } catch (e) {}
        var img = document.getElementById('np-cover');
        if (img && img.src) return img.src;
        return null;
      }

      function collect() {
        var title = (document.title || '').trim();
        var audio = getAudio();
        var cur = 0, total = 0, playing = false;
        if (audio) {
          cur = audio.currentTime || 0;
          total = audio.duration || 0;
          playing = !audio.paused;
        } else {
          var btn = document.getElementById('btn-play');
          var label = btn ? (btn.getAttribute('aria-label') || '') : '';
          var cls = btn ? btn.className : '';
          playing = label.indexOf('暂停') >= 0 || cls.indexOf('playing') >= 0 || cls.indexOf('pause') >= 0;
        }
        var box = document.getElementById('lyrics');
        var current = null, prev = null, next = null;
        if (box) {
          var active = box.querySelector('.ly.is-active');
          if (active) {
            current = lineText(active);
            var idx = parseInt(active.getAttribute('data-i') || '-1', 10);
            if (idx > 0) prev = lineText(box.querySelector('.ly[data-i="' + (idx - 1) + '"]'));
            next = lineText(box.querySelector('.ly[data-i="' + (idx + 1) + '"]'));
          }
        }
        // 喜欢态（展开页星标）：player.js 的 __liziLiked，未加载时按未喜欢算。
        var liked = false;
        try { if (typeof window.__liziLiked === 'function') liked = !!window.__liziLiked(); } catch (e) {}
        return {
          title: title,
          playing: playing,
          currentTime: cur,
          duration: total,
          currentLyric: current,
          prevLyric: prev,
          nextLyric: next,
          cover: coverUrl(),
          liked: liked
        };
      }

      function post() {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liziBridge;
          if (h) h.postMessage(collect());
        } catch (e) {}
      }

      setInterval(post, 1000);
    })();
    """
}

// MARK: - 原生端：收消息

/// 网页状态的一次快照。
struct LiziPlaybackSnapshot {
    let title: String
    let artist: String
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let currentLyric: String?
    let prevLyric: String?
    let nextLyric: String?
    /// 当前曲目的封面地址（Player.state.queue 里那首的 cover，缺省读 #np-cover）。
    let coverURL: String?
    /// 当前曲目是否已喜欢（player.js 的 __liziLiked，展开页星标用）。
    let isLiked: Bool
}

/// WKScriptMessageHandler：收 JS 每秒 post 过来的播放状态，转交给 coordinator。
final class LyricsBridge: NSObject, WKScriptMessageHandler {
    weak var coordinator: LiziIslandCoordinator?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "liziBridge",
              let body = message.body as? [String: Any] else { return }
        let titleRaw = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !titleRaw.isEmpty, titleRaw != "LIZI · 粒子播放器" else { return }
        // document.title 是 "歌名 · 歌手"（app.js 切歌时写的格式）
        let parts = titleRaw.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let title = parts.first ?? titleRaw
        let artist = parts.count > 1 ? parts[1] : ""
        let snap = LiziPlaybackSnapshot(
            title: title,
            artist: artist,
            isPlaying: (body["playing"] as? Bool) ?? false,
            currentTime: (body["currentTime"] as? Double) ?? 0,
            duration: (body["duration"] as? Double) ?? 0,
            currentLyric: body["currentLyric"] as? String,
            prevLyric: body["prevLyric"] as? String,
            nextLyric: body["nextLyric"] as? String,
            coverURL: body["cover"] as? String,
            isLiked: (body["liked"] as? Bool) ?? false
        )
        // WKScriptMessageHandler 回调在主线程；coordinator 不是 @MainActor，
        // 直接同步调用即可。
        coordinator?.receive(snapshot: snap, fromJS: true)
    }
}

// MARK: - 协调器：快照 → Live Activity

/// 把网页快照翻译成 Live Activity 状态。节流规则与岛上歌词一致：
/// 行变 / 切歌 / 播放暂停切换时立刻推；进度最多 5 秒推一次。
/// 注意：不是 @MainActor（WebHost 不是 MainActor，要同步创建它）。
final class LiziIslandCoordinator {
    let liveActivity = LiveActivityManager()
    let bridge = LyricsBridge()

    private(set) var currentLine: String = "♪"

    private var lastTitle = ""
    private var lastArtist = ""
    private var lastLine: String?
    private var lastPlaying: Bool?
    private var lastLiked: Bool?
    private var lastProgressUpdate: Date = .distantPast
    private let progressRefreshInterval: TimeInterval = 5
    /// JS 快照最后到达时间（第 14 轮第 11 件）：App 切后台后 JS 的 1 秒定时器
    /// 会被 iOS 节流/挂起；pollNowPlaying 拿它判断快照是不是停了。
    var lastJSSnapshotAt: Date = .distantPast

    // MARK: - 封面（第 12 轮第 15 件；第 13 轮第 9 件改走代理优先）

    /// 封面 URL → 下采样后的 JPEG（~120px，供灵动岛紧凑/展开视图）。
    private var coverCache: [String: Data] = [:]
    private var lastCoverURL: String?
    private var fetchingCoverURL: String?
    private var lastState: LiziLyricsAttributes.ContentState?
    /// 本地服务端口（ContentView 在 load(port:) 后填，默认 18791）：
    /// 封面先走本机 /api/img 代理（和 App 内封面同一条已验证的路），
    /// 直链只作兜底；相对地址（#np-cover 兜底）也要靠它拼成绝对地址。
    var serverPortProvider: () -> Int = { 18791 }

    init() {
        bridge.coordinator = self
    }

    func receive(snapshot: LiziPlaybackSnapshot, fromJS: Bool = false) {
        if fromJS { lastJSSnapshotAt = Date() }
        let trackChanged = snapshot.title != lastTitle || snapshot.artist != lastArtist
        let lineChanged = snapshot.currentLyric != lastLine
        let playChanged = snapshot.isPlaying != lastPlaying
        let likedChanged = snapshot.isLiked != lastLiked
        let coverChanged = snapshot.coverURL != lastCoverURL
        let now = Date()
        let progressDue = snapshot.isPlaying
            && now.timeIntervalSince(lastProgressUpdate) >= progressRefreshInterval
        guard trackChanged || lineChanged || playChanged || likedChanged || progressDue || coverChanged else { return }

        lastTitle = snapshot.title
        lastArtist = snapshot.artist
        lastLine = snapshot.currentLyric
        lastPlaying = snapshot.isPlaying
        lastLiked = snapshot.isLiked
        lastProgressUpdate = now
        if coverChanged {
            lastCoverURL = snapshot.coverURL
            fetchCover(urlString: snapshot.coverURL)
        }

        /* 第 13 轮第 19 件：没歌词的歌显示歌名，绝不用 ♪——♪ 是一条假歌词，
           看着像歌词没加载完，用户会以为岛坏了；歌名是这首歌真实的明确状态。
           歌词还没拉到（换歌瞬间 currentLyric 也是 null）时同样先显示歌名，
           词一到就被 lineChanged 推过来的真词换掉。 */
        let current = snapshot.currentLyric ?? snapshot.title
        currentLine = current
        let progress: Double
        if snapshot.duration > 0 {
            progress = min(max(snapshot.currentTime / snapshot.duration, 0), 1)
        } else {
            progress = 0
        }
        // 第 15 轮第 1 件：没封面的歌岛上也用默认图，不留空白/黑方块。
        // 锁屏那边早有 applyDefaultLockScreenCover()，岛这边原来取不到
        // 就是 nil，两边不对称。封面 URL 有、但还没拉到时仍是 nil，
        // 拉到了 didFetchCover 会补推；拉死透了 fetchCoverFrom 兜底默认图。
        let coverData = snapshot.coverURL.flatMap { coverCache[$0] }
            ?? (snapshot.coverURL == nil ? Self.defaultCoverData : nil)
        let state = LiziLyricsAttributes.ContentState(
            currentLyric: current,
            prevLyric: snapshot.prevLyric,
            nextLyric: snapshot.nextLyric,
            progress: progress,
            isPlaying: snapshot.isPlaying,
            duration: snapshot.duration,
            isLiked: snapshot.isLiked,
            coverData: coverData
        )
        lastState = state
        if trackChanged || !liveActivity.isRunning {
            liveActivity.startActivity(title: snapshot.title, artist: snapshot.artist, state: state)
        } else {
            liveActivity.updateActivity(state: state)
        }
    }

    /// 原生兜底快照（第 14 轮第 11 件）：App 切后台后 JS 的 1 秒定时器会被
    /// iOS 节流/挂起，快照一停、10 秒后 staleDate 过期岛就消失；锁屏/耳机
    /// 恢复播放时 App 还在后台，JS 快照不恢复，活动永不重起。
    /// pollNowPlaying（原生定时器，后台音频模式下仍跑）在播放中且 JS 快照
    /// 已 stale（>3 秒）时喂一个原生快照：标题/歌手/播放态/进度/封面 URL
    /// 用原生读到的真值；歌词用上次已知行（同曲保留，切歌时 nil 即显示歌名）。
    /// 暂停时不喂——让 staleDate 按设计清掉岛。
    func receiveNative(title: String, artist: String, isPlaying: Bool,
                       currentTime: Double, duration: Double,
                       coverURL: String?, isLiked: Bool) {
        let sameTrack = title == lastTitle && artist == lastArtist
        let snap = LiziPlaybackSnapshot(
            title: title, artist: artist, isPlaying: isPlaying,
            currentTime: currentTime, duration: duration,
            currentLyric: sameTrack ? lastLine : nil,
            prevLyric: nil, nextLyric: nil,
            coverURL: coverURL, isLiked: isLiked)
        receive(snapshot: snap)
    }

    /// 封面拉取（第 13 轮第 9 件重写）：先走本机 /api/img 代理，再走直链。
    /// 代理是 App 内封面同一条已验证的路（Referer/UA/https 升级都在服务端做，
    /// 日志 07:05:50 证明直链 http 会被 ATS -1022 秒拦、代理修好后才通）；
    /// 直链只在代理 502（host 不在白名单）时兜底。
    /// 相对地址（队列里没封面时桥读 #np-cover，拿到的是 /api/img?url=...）
    /// 拼成本机绝对地址再拉——相对地址直接给 URLSession 是拉不到的。
    private func fetchCover(urlString: String?) {
        guard let urlString, !urlString.isEmpty,
              fetchingCoverURL != urlString else { return }
        fetchingCoverURL = urlString
        let port = serverPortProvider()
        var urls: [URL] = []
        if urlString.hasPrefix("/") {
            if let u = URL(string: "http://127.0.0.1:\(port)\(urlString)") { urls.append(u) }
            // 第 15 轮第 1 件：相对地址常是 /api/img?url=<原地址>（#np-cover
            // 兜底）；原来只有代理一路，代理 403 即死。现在把原地址解出来
            // 再直连一次（http 升 https，ATS 才放行）。
            if let comps = URLComponents(string: urlString),
               let orig = comps.queryItems?.first(where: { $0.name == "url" })?.value,
               let rawURL = URL(string: orig),
               rawURL.scheme == "http" || rawURL.scheme == "https",
               var dcomps = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
                if dcomps.scheme == "http" { dcomps.scheme = "https" }
                if let direct = dcomps.url { urls.append(direct) }
            }
        } else if let rawURL = URL(string: urlString),
                  rawURL.scheme == "http" || rawURL.scheme == "https" {
            var comps = URLComponents(string: "http://127.0.0.1:\(port)/api/img")
            comps?.queryItems = [URLQueryItem(name: "url", value: urlString)]
            if let proxy = comps?.url { urls.append(proxy) }
            if var dcomps = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
                if dcomps.scheme == "http" { dcomps.scheme = "https" }
                if let direct = dcomps.url { urls.append(direct) }
            }
        }
        guard !urls.isEmpty else { fetchingCoverURL = nil; return }
        fetchCoverFrom(urls, at: 0, urlString: urlString)
    }

    /// 按候选顺序拉封面：非 2xx / 坏数据就试下一路，都死透才放手。
    /// 第 15 轮第 1 件：每一步记 DiagLog（lane + host + 状态），死透了
    /// 上默认图——下次真机报告能区分“代理 403 → 直链也死”还是“直链根本没跑”。
    private func fetchCoverFrom(_ urls: [URL], at index: Int, urlString: String) {
        guard index < urls.count else {
            fetchingCoverURL = nil
            DiagLog.shared.recordLog(category: "cover",
                message: "island cover all lanes failed, using default: \(urlString.prefix(80))",
                fields: ["reason": "island-cover-all-failed", "lane": "island"])
            if let d = Self.defaultCoverData, coverCache[urlString] == nil {
                coverCache[urlString] = d
                if var s = lastState, lastCoverURL == urlString {
                    s.coverData = d
                    lastState = s
                    pushCoverState(s)
                }
            }
            return
        }
        let lane = urls[index].host == "127.0.0.1" ? "proxy" : "direct"
        URLSession.shared.dataTask(with: urls[index]) { [weak self] data, resp, _ in
            guard let self else { return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let okStatus = (200..<300).contains(status)
            if okStatus, let data, let image = UIImage(data: data),
               let thumb = Self.downsample(image, to: 120) {
                DiagLog.shared.recordLog(category: "cover",
                    message: "island cover ok lane=\(lane) host=\(urls[index].host ?? "")",
                    fields: ["host": urls[index].host ?? "", "reason": "island-cover-ok", "lane": lane])
                DispatchQueue.main.async { self.didFetchCover(thumb, urlString: urlString) }
            } else {
                DiagLog.shared.recordLog(category: "cover",
                    message: "island cover lane=\(lane) failed host=\(urls[index].host ?? "") status=\(status)",
                    fields: ["host": urls[index].host ?? "", "reason": "island-cover-lane-failed", "code": status, "lane": lane])
                DispatchQueue.main.async { self.fetchCoverFrom(urls, at: index + 1, urlString: urlString) }
            }
        }.resume()
    }

    /// 岛的默认封面（第 15 轮第 1 件）：和锁屏默认图同一画法（深色渐变底 + ♪），
    /// 下采样到 120px；没封面的歌、封面死透的歌都用它，岛上不留空白/黑方块。
    private static let defaultCoverData: Data? = {
        let size = CGSize(width: 1000, height: 1000)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
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
        return downsample(image, to: 120)
    }()

    private func didFetchCover(_ thumb: Data, urlString: String) {
        fetchingCoverURL = nil
        coverCache[urlString] = thumb
        if coverCache.count > 8 {
            let keep = coverCache[urlString]
            coverCache.removeAll()
            if let keep { coverCache[urlString] = keep }
        }
        // 封面到了、歌还没换：把上次推过的 state 补上封面再推一次。
        guard var s = lastState, lastCoverURL == urlString else { return }
        s.coverData = thumb
        lastState = s
        pushCoverState(s)
    }

    /// 封面补推：activity 还在启动中（startActivity 的 Task 没跑完）时
    /// updateActivity 是 no-op，0.6s 后重试一次；5 秒进度推送是最后兜底。
    private func pushCoverState(_ s: LiziLyricsAttributes.ContentState) {
        if liveActivity.isRunning {
            liveActivity.updateActivity(state: s)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let cur = self.lastState,
                  cur.coverData == s.coverData, self.lastCoverURL != nil,
                  self.liveActivity.isRunning else { return }
            self.liveActivity.updateActivity(state: cur)
        }
    }

    private static func downsample(_ image: UIImage, to px: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = px / max(size.width, size.height)
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        UIGraphicsBeginImageContextWithOptions(target, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: target))
        return UIGraphicsGetImageFromCurrentImageContext()?.jpegData(compressionQuality: 0.8)
    }

    /// 歌停了时收掉岛。平时靠 staleDate 10s 自动消失，这里是显式收尾。
    func endIsland() {
        liveActivity.endActivity()
        lastTitle = ""
        lastArtist = ""
        lastLine = nil
        lastPlaying = nil
        lastLiked = nil
        lastCoverURL = nil
        fetchingCoverURL = nil
        lastState = nil
    }
}
