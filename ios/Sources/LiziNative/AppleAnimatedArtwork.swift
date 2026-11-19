import Foundation
import MediaPlayer
import UIKit

/// 路线 B：苹果真实动态封面（Album Motion / editorialVideo）——锁屏用。
///
/// 本文件是新增文件，不改 AnimatedArtwork.swift（路线 A 本地生成）、
/// NowPlayingCoordinator.swift、PlayerView/CoverFlowView。集成接线见文件尾。
///
/// ── 实测结论（2026-11-20，VM 上 curl/Node 实测，非凭记忆） ──
/// 入口：
/// - 唯一可用的入口是 amp-api.music.apple.com：
///   GET /v1/catalog/{storefront}/albums/{id}?extend=editorialVideo
///   必须带 `Origin: https://music.apple.com`，否则 401（实测：无 Origin → 401，
///   无 token → 401，有 token 无 Origin → 401，有 token + Origin → 200）。
/// - 官方 api.music.apple.com 同一个 token 也返回 200，但响应里没有 editorialVideo
///   （extend 被忽略），所以必须走 amp-api，不能走官方 host。
/// - catalog 元数据不需要登录、不需要订阅、不需要 media-user-token：实测全程只发了
///   开发者 token，没有发任何用户 token。
/// 鉴权（开发者 token，二选一）：
/// - 首选用户已粘贴的 MusicKit 开发者 token（UserDefaults `lizi.applemusic.devtoken`，
///   设置里已有粘贴入口，见 AppleMusic.swift；有自己的 token 时走自己的配额）。
///   注意：用户自己的 token 在 amp-api 上是否被接受，VM 上无法验证（用户还没提供过
///   token）——代码里先试用户 token，401/403 就自动改用网页 token重试一次。
/// - 没有用户 token 时，现抠网页播放器 token：GET https://music.apple.com →
///   找 /assets/index~*.js → 在 JS 里找 iss=AMPWebPlay 的 JWT。
///   实测 2026-11-20：首页 HTML（2,410,162 字节）只引用一个 bundle
///   index~B8RKPfmaCI.js（3,351,039 字节）；token 在其中，header
///   {"typ":"JWT","alg":"ES256","kid":"WebPlayKid"}，payload
///   {"iss":"AMPWebPlay","iat":1793900708,"exp":1799948708}，
///   即 2026-11-05 签发、2027-01-14 过期，约 70 天有效。
///   旧文档写的 `eyJh` 前缀正则已失效（现在的 JWT 头以 `eyJ0` 开头），本文件按
///   payload 的 `eyJpc3MiOiJBTVBXZWJQbGF5`（{"iss":"AMPWebPlay"）定位，不要抄旧正则。
///   这是 music.apple.com 网页播放器公开自带的 token（任何浏览器打开网页就能拿到），
///   不是用户私密凭证；缓存只存到 exp 为止，401 即重抠。苹果随时可能改 bundle 结构，
///   抠不到就回落路线 A。另：该 token 是全网共用的，配额也是共用的，大量查 catalog
///   可能被限流（429），本文件对单张专辑只查一次 + 否定结果记 7 天，不反复刷。
/// 素材：
/// - editorialVideo 含 motionDetailSquare / motionDetailTall（另有
///   motionSquareVideo1x1 / motionTallVideo3x4 是同一对的重命名，四键同值），
///   每项含 previewFrame（mzstatic png 模板，{w}x{h} 占位）+ video（master m3u8，
///   mvod.itunes.apple.com）。单曲级 ?extend=editorialVideo 返回 200 但无此字段，
///   必须走专辑级。
/// - master m3u8 无鉴权可拉（Content-Type: application/vnd.apple.mpegurl；实测
///   Midnights 方形/竖版各 29 个 #EXT-X-STREAM-INF，H.264(avc1)+HEVC(hvc1)，
///   30fps，分辨率方形 360–1080、竖版 310x414–1080x1440）。
/// - variant playlist URI 把后缀 `.m3u8` 换成 `.mp4`（保留 `_-.`，即 `..._-.mp4`）
///   就是可直接下载的完整 fMP4（无鉴权，Content-Type: video/mp4，头 16 字节
///   `0000001c66747970 69736f35` = ftyp iso5；换成 `-.mp4` 或 `--.mp4` 都是 404）。
///   实测：Midnights 方形 768x768 H.264 30fps，680 帧 / 22.67 秒，5,991,277 字节，
///   sha256 edacf615…052b8a5；竖版 830x1106 H.264 30fps，30.0 秒，7,304,538 字节，
///   sha256 b384b5d5…065d98b4；均无音轨（ffprobe 只有一条 video 流）。第 0 帧与
///   第 12 秒帧逐像素平均差异 3.6/通道——是真在动的循环（Midnights 本身动得柔和），
///   不是静态图。苹果 Album Motion 规范：方形 3840x3840、竖版 2048x2732、8–35 秒、
///   H.264/ProRes、无声、首帧 = 静态封面。
/// 匹配：
/// - Apple Music 的歌：songs/{id}?include=albums 拿专辑 id（实测 1721454344 →
///   专辑 1721454339）。其他平台的歌：amp-api 搜索 "歌手 专辑名"，取首个专辑，
///   归一化（去大小写/标点/空白）后要求歌手与专辑名双向包含其一才算命中，否则
///   不硬配、返回 nil 走路线 A。专辑 id 是分店面的（us 的 id 在 tw 查会 404），
///   按 us → tw → hk 顺序试。
/// - 有素材的专辑实测：IVE REVIVE+（1873882195）、Taylor Swift《Midnights》
///   （1649434996）、周杰伦《Greatest Works Of Art》（1721454339，us 店面）。
///   无素材的专辑实测：王菲《寓言》（966489223）、Album Leaf《In a Safe Place》
///   （15405970）、《Into the Blue Again》（183211887）——editorialVideo 字段
///   根本不存在，走路线 A。中文搜索也通（"周杰伦 最伟大的作品" 在 us 店面搜到
///   正确专辑排第一）。
/// 缓存与回落：
/// - Caches/apple-animated-artwork/<key>-p.mp4 / -s.mp4（竖版 3:4 供锁屏、方形
///   1:1 备用），与路线 A 的 animated-artwork/ 目录分开；预览图同目录存
///   <key>-p.jpg / -s.jpg（previewFrame 模板按 720x960 / 720x720 取）。
/// - 上限 8 张专辑、TTL 30 天，超限删最旧；否定结果（无素材/匹配不上）只记内存
///   7 天，不写盘。任何一步失败 → prepare 回调 false，调用方走路线 A，绝不崩、
///   绝不返回半截文件（先下 tmp 再换名；下载后验 ftyp + 大小 > 100KB 才认）。
/// - 岛上（Live Activity 扩展）暂时用不上本文件：扩展 target 只编
///   Sources/LiziNativeLiveActivity/，且项目里没有 App Groups，扩展读不到主 App
///   的 Caches；岛上真视频要么配 App Group（需付费开发者账号，与 kun 签名同款
///    blocker），要么扩展内自拉（见文件尾）。本文件先只供锁屏（主 App 进程内
///   MPNowPlayingInfoCenter），不碰扩展。
final class AppleAnimatedArtworkProvider {
    static let shared = AppleAnimatedArtworkProvider()

    enum Aspect {
        case portrait  // 3:4，锁屏全屏铺满用（与路线 A 同尺寸 720x960 目标）
        case square    // 1:1，备用
        var suffix: String {
            switch self {
            case .portrait: return "-p"
            case .square: return "-s"
            }
        }
        /// 挑 variant 时的目标宽度：不低于它取最小档（省流量/磁盘）。
        var targetWidth: Int {
            switch self {
            case .portrait: return 720
            case .square: return 720
            }
        }
        /// editorialVideo 里对应的键。
        var editorialKey: String {
            switch self {
            case .portrait: return "motionDetailTall"
            case .square: return "motionDetailSquare"
            }
        }
        /// previewFrame 模板的取图尺寸。
        var previewSize: (w: Int, h: Int) {
            switch self {
            case .portrait: return (720, 960)
            case .square: return (720, 720)
            }
        }
    }

    /// 缓存键前缀：与路线 A 的键（封面 URL 的 SHA256）区分开，避免串目录。
    private static let keyPrefix = "am"
    private static let maxCachedAlbums = 8
    private static let cacheTTL: TimeInterval = 30 * 24 * 3600
    private static let negativeTTL: TimeInterval = 7 * 24 * 3600
    private static let requestTimeout: TimeInterval = 15
    private static let storefronts = ["us", "tw", "hk"]

    private static let webTokenKey = "lizi.applemusic.webtoken"
    private static let webTokenExpKey = "lizi.applemusic.webtoken.exp"
    /// 用户自己的 MusicKit 开发者 token（与 AppleMusic.swift 的 devTokenKey 同值，
    /// 设置里已有粘贴入口；这里不用跨文件引用常量，免得以后挪文件时断链）。
    private static let userDevTokenKey = "lizi.applemusic.devtoken"

    private let lock = NSLock()
    private var webToken: String?
    private var webTokenExp: Date?
    /// 进行中的 prepare：同 key 的并发请求合并，只拉一次。
    private var inflight: [String: [(Bool) -> Void]] = [:]
    /// 否定结果（无素材 / 匹配不上）：key →（记入时间，结论 lane），7 天内不再重复查。
    /// lane 跟着存：否定缓存命中时也要按首歌把结论重记一笔，否则 7 天内再播
    /// 这首歌，诊断里看不到路线 B 的任何结论（r20 补）。
    private var negatives: [String: (date: Date, lane: String)] = [:]
    /// 最近一次按 key 落定的路线 B 结论 lane（五个结论之一）：prepare 同 key
    /// 合并调用（第二首歌）回调时，按这个 lane 给那首歌补记一笔。
    private var lastConclusion: [String: String] = [:]
    /// 本次 resolve 里 amp-api 失败过的 key（token/网络/限流）：ampGet 全部
    /// 尝试耗尽时记入。resolve 据此把“查不到”与“没查成”分开——没查成记
    /// route-b-download-failed，不记否定（瞬时问题，下次还查）；只有确定
    /// “无匹配 / 无 editorialVideo”才记否定（r20 补）。

    private init() {}

    // MARK: - 对外接口（供 NowPlayingCoordinator 集成，见文件尾接线）

    /// 曲目的缓存键（专辑已解析出来时才非 nil；解析要走网络时先返回 nil，
    /// 调用方等 prepare 回调）。Apple Music 的歌用 "am:<店面>:<专辑 id>"；
    /// 其他平台的歌用 "am:match:<歌手|专辑名> 的 SHA256 前 16 位"。
    func albumKey(for track: Track) -> String? {
        if track.platform == "applemusic", let id = appleAlbumIdHint(for: track) {
            return "\(Self.keyPrefix):\(id)"
        }
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !album.isEmpty else { return nil }
        return "\(Self.keyPrefix):match:\(Self.shortHash("\(artist)|\(album)"))"
    }

    /// 某长宽比的真视频是否已在磁盘上（只信文件不信内存，Caches 可能被系统清掉）。
    func isReady(key: String, aspect: Aspect) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(key: key, aspect: aspect).path)
    }

    /// 锁屏主用：竖版就绪即算可用（方形是备用，缺了不影响锁屏）。
    func isReady(key: String) -> Bool { isReady(key: key, aspect: .portrait) }

    /// 为一首歌准备真视频：已就绪立刻回调 true；否则走网络解析 + 下载，
    /// 竖版到手回调 true，任何失败回调 false（调用方走路线 A）。
    /// 同 key 并发调用合并为一次网络请求。
    func prepare(for track: Track, onReady: @escaping (Bool) -> Void) {
        guard let key = albumKey(for: track) else {
            // 歌手或专辑名为空（单曲常无专辑名）：路线 B 匹配不了，直接认栽，
            // 调用方走路线 A。记一笔——否则“《海嶼你》这类歌 B 为什么没动”
            // 在诊断里完全看不到。
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B skipped, no artist/album to match track=\(track.title) artist=\(track.artist) album=\(track.album)",
                fields: ["lane": "route-b-no-key", "platform": track.platform])
            onReady(false); return
        }
        if isReady(key: key) {
            // 缓存已就绪也是一个结论：记 route-b-ready，否则已缓存的专辑再播时
            // 诊断里看不到路线 B 的任何结论（r20 补：用户体感“全是本地生成”
            // 的一半原因——真视频明明已缓存挂上，诊断却没留痕）。
            lock.lock(); lastConclusion[key] = "route-b-ready"; lock.unlock()
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B ready (cached) track=\(track.title) artist=\(track.artist) album=\(track.album)",
                fields: ["lane": "route-b-ready", "platform": track.platform])
            onReady(true); return
        }
        lock.lock()
        if inflight[key] != nil {
            // 同 key 第二首歌（同专辑另一首歌在 resolve 还没完时切来）：等首歌
            // 的 resolve 落定后，按落定的 lane 给这首歌也记一笔结论（r20 补），
            // 否则这首歌在诊断里没有路线 B 结论。
            let wrapped: (Bool) -> Void = { [weak self] ok in
                guard let self else { onReady(ok); return }
                self.lock.lock()
                let lane = self.lastConclusion[key] ?? (ok ? "route-b-ready" : "route-b-download-failed")
                self.lock.unlock()
                let short = lane.replacingOccurrences(of: "route-b-", with: "")
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B \(short) (shared prepare) track=\(track.title) artist=\(track.artist) album=\(track.album)",
                    fields: ["lane": lane, "platform": track.platform])
                onReady(ok)
            }
            inflight[key]?.append(wrapped)
            lock.unlock()
            return
        }
        inflight[key] = [onReady]
        lock.unlock()
        Task {
            let ok = await self.resolveAndDownload(track: track, key: key)
            self.lock.lock()
            let callbacks = self.inflight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            for cb in callbacks {
                DispatchQueue.main.async { cb(ok) }
            }
        }
    }

    /// 已就绪时返回可直接放进 nowPlayingInfo 的动态封面对象；iOS 26 以下永远返回 nil。
    /// artworkID 带 `lizi-apple-` 前缀，与路线 A 的 `lizi-` 区分开——系统以此识别
    /// 素材是否换过；真视频与路线 A 的 Ken Burns 视频绝不共用同一个 ID。
    func artwork(forKey key: String, aspect: Aspect) -> Any? {
        if #available(iOS 26.0, *) {
            guard isReady(key: key, aspect: aspect) else { return nil }
            return makeArtwork(key: key, aspect: aspect)
        } else {
            return nil
        }
    }

    // MARK: - 专辑解析

    /// Apple Music 的歌：track.albumId 只有平台是 applemusic 时才是苹果专辑 id
    /// （其他平台的 albumId 是该平台自己的 id，不能直接当苹果 id 用）。
    private func appleAlbumIdHint(for track: Track) -> String? {
        guard track.platform == "applemusic" else { return nil }
        return track.albumId.isEmpty ? nil : track.albumId
    }

    /// Apple Music 单曲 id：id 是 "am-<songId>"，platformKey 是原始 id。
    private func appleSongId(for track: Track) -> String? {
        guard track.platform == "applemusic" else { return nil }
        if !track.platformKey.isEmpty {
            let k = track.platformKey
            return k.hasPrefix("am-") ? String(k.dropFirst(3)) : k
        }
        let id = track.id
        return id.hasPrefix("am-") ? String(id.dropFirst(3)) : id
    }

    /// 解析专辑并下载两版视频。返回 true = 竖版已就绪（方形尽力而为）。
    private func resolveAndDownload(track: Track, key: String) async -> Bool {
        // 否定结果在有效期内：直接认栽，不重复查——但结论要重记一笔（r20 补）：
        // 否则 7 天内再播这首歌，诊断里看不到路线 B 的任何结论。
        lock.lock()
        let neg = negatives[key]
        ampFailedKeys.remove(key)
        lock.unlock()
        if let neg, Date().timeIntervalSince(neg.date) < Self.negativeTTL {
            lock.lock(); lastConclusion[key] = neg.lane; lock.unlock()
            let short = neg.lane.replacingOccurrences(of: "route-b-", with: "")
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B \(short) (cached negative) track=\(track.title) artist=\(track.artist) album=\(track.album)",
                fields: ["lane": neg.lane, "platform": track.platform])
            return false
        }
        // 1. 拿专辑 id + 所在店面（hint 路径顺带把 editorialVideo 也拿了，免得再查一次）。
        var album: (id: String, storefront: String)?
        var editorial: [String: Any]?
        if track.platform == "applemusic" {
            if let hint = appleAlbumIdHint(for: track) {
                for sf in Self.storefronts {
                    if let ed = await fetchEditorialVideo(albumId: hint, storefront: sf, key: key) {
                        album = (hint, sf)
                        editorial = ed
                        break
                    }
                }
            }
            if album == nil, let songId = appleSongId(for: track) {
                album = await albumIdForSong(songId, key: key)
            }
        }
        if album == nil {
            album = await albumIdBySearch(artist: track.artist, album: track.album, key: key)
        }
        guard let album else {
            // 查不到分两种：amp-api 没查成（token/网络/限流）→ download-failed，
            // 不记否定；真查了没匹配上 → no-match，记否定（r20 补：之前两种
            // 都记 no-match，token 死掉时全锅都算到“匹配不上”头上）。
            lock.lock()
            let ampFailed = ampFailedKeys.contains(key)
            lock.unlock()
            if ampFailed {
                lock.lock(); lastConclusion[key] = "route-b-download-failed"; lock.unlock()
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B amp-api failed, album lookup inconclusive track=\(track.title) artist=\(track.artist) album=\(track.album)",
                    fields: ["lane": "route-b-download-failed", "platform": track.platform])
                return false
            }
            markNegative(key, lane: "route-b-no-match")
            lock.lock(); lastConclusion[key] = "route-b-no-match"; lock.unlock()
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B no album match track=\(track.title) artist=\(track.artist) album=\(track.album)",
                fields: ["lane": "route-b-no-match", "platform": track.platform])
            return false
        }
        // 2. 拉 editorialVideo（hint 路径已拿到就不再拉）。
        if editorial == nil {
            editorial = await fetchEditorialVideo(albumId: album.id, storefront: album.storefront, key: key)
        }
        guard let editorial else {
            // 同上：没查成（token/网络）→ download-failed 不记否定；
            // 真查了专辑无 editorialVideo → no-video，记否定。
            lock.lock()
            let ampFailed = ampFailedKeys.contains(key)
            lock.unlock()
            if ampFailed {
                lock.lock(); lastConclusion[key] = "route-b-download-failed"; lock.unlock()
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B amp-api failed, editorialVideo lookup inconclusive albumId=\(album.id) storefront=\(album.storefront) track=\(track.title)",
                    fields: ["lane": "route-b-download-failed", "albumId": album.id, "storefront": album.storefront, "platform": track.platform])
                return false
            }
            markNegative(key, lane: "route-b-no-video")
            lock.lock(); lastConclusion[key] = "route-b-no-video"; lock.unlock()
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B album has no editorialVideo albumId=\(album.id) storefront=\(album.storefront) track=\(track.title)",
                fields: ["lane": "route-b-no-video", "albumId": album.id, "storefront": album.storefront, "platform": track.platform])
            return false
        }
        // 3. 两版视频各下一份（竖版是主用，方形尽力）。
        async let portrait = downloadAspect(editorial: editorial, key: key, aspect: .portrait)
        async let square = downloadAspect(editorial: editorial, key: key, aspect: .square)
        let portraitOK = await portrait
        _ = await square
        if portraitOK {
            pruneCache(keeping: key)
            lock.lock(); lastConclusion[key] = "route-b-ready"; lock.unlock()
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B ready albumId=\(album.id) storefront=\(album.storefront) track=\(track.title)",
                fields: ["lane": "route-b-ready", "albumId": album.id, "storefront": album.storefront, "platform": track.platform])
        } else {
            // r20：视频下载失败不记否定——下载失败多是瞬时网络/限流问题，
            // 记 7 天否定会把一首明明有真素材的专辑判死 7 天（进程内），
            // 下次 prepare 直接认栽、连重试的机会都没有；只有“无匹配 /
            // 专辑根本无 editorialVideo”这两种确定性结论才记否定（见上）。
            lock.lock(); lastConclusion[key] = "route-b-download-failed"; lock.unlock()
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B video download failed albumId=\(album.id) storefront=\(album.storefront) track=\(track.title)",
                fields: ["lane": "route-b-download-failed", "albumId": album.id, "storefront": album.storefront, "platform": track.platform])
        }
        return portraitOK
    }

    private func markNegative(_ key: String, lane: String) {
        lock.lock()
        negatives[key] = (Date(), lane)
        lock.unlock()
    }

    /// 单曲 → 专辑：songs/{id}?include=albums，取 relationships.albums.data[0].id。
    private func albumIdForSong(_ songId: String, key: String) async -> (id: String, storefront: String)? {
        for sf in Self.storefronts {
            guard let data = try? await ampGet(path: "/v1/catalog/\(sf)/songs/\(songId)?include=albums", key: key),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]],
                  let first = list.first,
                  let rel = first["relationships"] as? [String: Any],
                  let albums = rel["albums"] as? [String: Any],
                  let albumList = albums["data"] as? [[String: Any]],
                  let albumId = albumList.first?["id"] as? String, !albumId.isEmpty else { continue }
            return (albumId, sf)
        }
        return nil
    }

    /// 其他平台的歌：按 "歌手 专辑名" 在 amp-api 搜专辑，首个双向匹配的才算命中。
    /// 只比歌手 + 专辑名，不比歌名（同一专辑的歌共用一个动态封面；歌名不参与匹配，
    /// 免得单曲与专辑版同名不同盘时配错）。
    private func albumIdBySearch(artist: String, album: String, key: String) async -> (id: String, storefront: String)? {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !albumName.isEmpty else { return nil }
        let term = "\(artist) \(albumName)"
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        for sf in Self.storefronts {
            guard let data = try? await ampGet(path: "/v1/catalog/\(sf)/search?types=albums&term=\(encoded)&limit=5", key: key),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [String: Any],
                  let albums = results["albums"] as? [String: Any],
                  let list = albums["data"] as? [[String: Any]] else { continue }
            for item in list {
                guard let id = item["id"] as? String,
                      let attr = item["attributes"] as? [String: Any],
                      let name = attr["name"] as? String,
                      let itemArtist = attr["artistName"] as? String,
                      Self.matches(artist: artist, album: albumName, candidateArtist: itemArtist, candidateAlbum: name) else { continue }
                return (id, sf)
            }
            // 该店面搜到了专辑但没一个双向匹配：别换店面硬找了，直接判无匹配。
            if !list.isEmpty { return nil }
        }
        return nil
    }

    /// 双向匹配：归一化后，歌手与专辑名各取「相等 或 一方包含另一方」。
    /// 归一化去大小写/标点/空白/全半角差异；中文原样比对。
    static func matches(artist: String, album: String, candidateArtist: String, candidateAlbum: String) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased()
                .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined() ?? s.lowercased()
        }
        func hit(_ a: String, _ b: String) -> Bool {
            let na = norm(a), nb = norm(b)
            guard !na.isEmpty, !nb.isEmpty else { return false }
            return na == nb || na.contains(nb) || nb.contains(na)
        }
        return hit(artist, candidateArtist) && hit(album, candidateAlbum)
    }

    /// 拉一张专辑的 editorialVideo（无此字段返回 nil = 该专辑没有真素材）。
    /// 注意：官方 api.music.apple.com 同 token 返回 200 但无此字段，必须走 amp-api。
    private func fetchEditorialVideo(albumId: String, storefront: String, key: String) async -> [String: Any]? {
        guard let data = try? await ampGet(path: "/v1/catalog/\(storefront)/albums/\(albumId)?extend=editorialVideo", key: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]],
              let first = list.first,
              let attr = first["attributes"] as? [String: Any],
              let editorial = attr["editorialVideo"] as? [String: Any], !editorial.isEmpty else { return nil }
        return editorial
    }

    // MARK: - m3u8 → mp4

    /// 下一版视频：editorialVideo → master m3u8 → 挑 H.264 档 → 派生 mp4 直链 → 下载校验。
    /// 返回 true = 该版视频已在磁盘上且通过校验。
    private func downloadAspect(editorial: [String: Any], key: String, aspect: Aspect) async -> Bool {
        let dest = fileURL(key: key, aspect: aspect)
        if FileManager.default.fileExists(atPath: dest.path) { return true }
        guard let variant = editorial[aspect.editorialKey] as? [String: Any],
              let masterURLString = variant["video"] as? String,
              let masterURL = URL(string: masterURLString),
              let masterText = try? await fetchText(url: masterURL),
              let mp4URLString = Self.pickMP4URL(fromMaster: masterText, targetWidth: aspect.targetWidth),
              let mp4URL = URL(string: mp4URLString) else { return false }
        // 预览图尽力而为：失败不影响视频。
        if let preview = variant["previewFrame"] as? [String: Any],
           let template = preview["url"] as? String {
            let size = aspect.previewSize
            let urlString = template
                .replacingOccurrences(of: "{w}", with: "\(size.w)")
                .replacingOccurrences(of: "{h}", with: "\(size.h)")
            if let url = URL(string: urlString),
               let data = try? await fetchData(url: url), !data.isEmpty {
                try? data.write(to: previewURL(key: key, aspect: aspect), options: .atomic)
            }
        }
        guard let tmpURL = try? await downloadToTemp(url: mp4URL),
              isValidMP4(at: tmpURL) else { return false }
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
    }

    /// 从 master m3u8 里挑一档：只要 H.264（avc1，不用 HEVC，兼容最稳），
    /// 取宽度 ≥ 目标宽度的最小档；没有达标的取最大档。
    /// variant playlist URI 的 `.m3u8` → `.mp4`（保留 `_-.`）即完整 fMP4 直链。
    static func pickMP4URL(fromMaster text: String, targetWidth: Int) -> String? {
        let lines = text.components(separatedBy: .newlines)
        var candidates: [(width: Int, url: String)] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-STREAM-INF"), line.contains("avc1"),
               let resRange = line.range(of: "RESOLUTION=") {
                let rest = line[resRange.upperBound...]
                let res = rest.split(separator: ",").first.map(String.init) ?? ""
                let parts = res.split(separator: "x").compactMap { Int($0) }
                if parts.count == 2, i + 1 < lines.count {
                    let uri = lines[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if uri.hasPrefix("https://") { candidates.append((parts[0], uri)) }
                }
            }
            i += 1
        }
        guard !candidates.isEmpty else { return nil }
        let fitting = candidates.filter { $0.width >= targetWidth }.sorted { $0.width < $1.width }
        let chosen = fitting.first ?? candidates.sorted { $0.width > $1.width }.first!
        guard chosen.url.hasSuffix(".m3u8") else { return nil }
        return String(chosen.url.dropLast(".m3u8".count)) + ".mp4"
    }

    /// 校验：大小 > 100KB 且第 4–8 字节是 "ftyp"（实测 Midnights 的 mp4 头就是 ftyp iso5）。
    private func isValidMP4(at url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 100_000,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12 else { return false }
        return head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70 // "ftyp"
    }

    // MARK: - amp-api 请求（含 token 获取）

    /// amp-api GET：必须带 Origin，否则 401。先试用户 token（有就优先用自己的配额），
    /// 401/403 时改用网页 token 各重试一次；网页 token 过期/失效时重抠一次。
    /// key：本次 resolve 的专辑键——全部尝试耗尽时把 key 记进 ampFailedKeys，
    /// 调用方据此把“没查成”（token/网络/限流）与“查了没有”分开记（r20 补）。
    private func ampGet(path: String, key: String) async throws -> Data {
        guard let url = URL(string: "https://amp-api.music.apple.com" + path) else {
            throw AmpError.http(0)
        }
        var lastError: Error?
        // 顺序：用户 token → 网页 token；每种最多试两次（第二次是刷新后重试）。
        let userToken = UserDefaults.standard.string(forKey: Self.userDevTokenKey) ?? ""
        var attempts: [(token: String, refreshWeb: Bool)] = []
        if !userToken.isEmpty { attempts.append((userToken, false)) }
        attempts.append((await webTokenForRequest(), true))
        for (index, attempt) in attempts.enumerated() {
            guard !attempt.token.isEmpty else { continue }
            do {
                let (data, resp) = try await fetchDataWithHeaders(
                    url: url, headers: ["Authorization": "Bearer \(attempt.token)"])
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                if status == 401 || status == 403 {
                    // 用户 token 被拒：换网页 token（下一轮）；网页 token 被拒：重抠一次再试。
                    if attempt.refreshWeb, index == attempts.count - 1 {
                        refreshWebTokenCache()
                        let fresh = await webTokenForRequest(forceRefresh: true)
                        if !fresh.isEmpty {
                            let (data2, resp2) = try await fetchDataWithHeaders(
                                url: url, headers: ["Authorization": "Bearer \(fresh)"])
                            if (resp2 as? HTTPURLResponse)?.statusCode == 200 { return data2 }
                        }
                    }
                    continue
                }
                // 429（共用 token 被限流）与 5xx：不定论，直接当失败，不硬刷。
                throw AmpError.http(status)
            } catch let e as AmpError {
                lastError = e
            } catch {
                lastError = error
            }
        }
        // 全部尝试耗尽：把 key 记进 ampFailedKeys，调用方据此把“没查成”
        // 与“查了没有”分开记（r20 补）；不记否定，下次还查。
        lock.lock(); ampFailedKeys.insert(key); lock.unlock()
        throw lastError ?? AmpError.noToken
    }

    private enum AmpError: Error {
        case http(Int)
        case noToken
    }

    /// 网页 token：内存/磁盘缓存未过期就复用，否则现抠。forceRefresh = 忽略缓存重抠。
    private func webTokenForRequest(forceRefresh: Bool = false) async -> String {
        if !forceRefresh {
            lock.lock()
            let cached = webToken
            let exp = webTokenExp
            lock.unlock()
            if let cached, !cached.isEmpty, let exp, exp > Date().addingTimeInterval(3600) {
                return cached
            }
            if let saved = UserDefaults.standard.string(forKey: Self.webTokenKey),
               !saved.isEmpty,
               let savedExp = UserDefaults.standard.object(forKey: Self.webTokenExpKey) as? Date,
               savedExp > Date().addingTimeInterval(3600) {
                lock.lock()
                webToken = saved
                webTokenExp = savedExp
                lock.unlock()
                return saved
            }
        }
        guard let (token, exp) = await scrapeWebToken() else { return "" }
        lock.lock()
        webToken = token
        webTokenExp = exp
        lock.unlock()
        UserDefaults.standard.set(token, forKey: Self.webTokenKey)
        UserDefaults.standard.set(exp, forKey: Self.webTokenExpKey)
        return token
    }

    private func refreshWebTokenCache() {
        lock.lock()
        webToken = nil
        webTokenExp = nil
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.webTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.webTokenExpKey)
    }

    /// 抠网页播放器 token：GET music.apple.com → /assets/index~*.js → 找
    /// iss=AMPWebPlay 的 JWT。注意头是 `eyJ0` 开头不是 `eyJh`，按 payload 前缀定位。
    /// 返回 (token, exp)。token 是网页播放器公开自带的，不是用户私密凭证。
    private func scrapeWebToken() async -> (String, Date)? {
        let ua = Self.browserUserAgent
        guard let homeURL = URL(string: "https://music.apple.com"),
              let homeData = try? await fetchData(url: homeURL, userAgent: ua),
              let home = String(data: homeData, encoding: .utf8) else { return nil }
        let bundlePattern = "/assets/index~[^\"'\\s]*\\.js"
        guard let bundleRegex = try? NSRegularExpression(pattern: bundlePattern),
              let match = bundleRegex.firstMatch(in: home, range: NSRange(home.startIndex..., in: home)),
              let bundleRange = Range(match.range, in: home) else { return nil }
        let bundlePath = String(home[bundleRange])
        guard let bundleURL = URL(string: "https://music.apple.com" + bundlePath),
              let jsData = try? await fetchData(url: bundleURL, userAgent: ua),
              let js = String(data: jsData, encoding: .utf8) else { return nil }
        // JWT = header.payload.signature；payload 以 {"iss":"AMPWebPlay" 开头，
        // base64url 后是 eyJpc3MiOiJBTVBXZWJQbGF5。
        let tokenPattern = "eyJ[A-Za-z0-9_-]+\\.eyJpc3MiOiJBTVBXZWJQbGF5[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"
        guard let tokenRegex = try? NSRegularExpression(pattern: tokenPattern),
              let tokenMatch = tokenRegex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let tokenRange = Range(tokenMatch.range, in: js) else { return nil }
        let token = String(js[tokenRange])
        guard let exp = Self.expiry(ofJWT: token) else { return nil }
        DiagLog.shared.recordLog(category: "apple-animated-artwork",
            message: "web player token scraped, exp=\(exp)",
            fields: ["lane": "route-b-token"])
        return (token, exp)
    }

    /// 解 JWT payload 的 exp（只读时间戳，不碰签名、不校验签名——苹果的 token 我们只当
    /// 不透明凭证用，服务端会校验）。
    static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - 网络小件

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// amp-api 请求头：Origin 是强制的（实测缺 Origin 即 401），UA 用浏览器 UA
    /// （amp-api 是网页播放器的后端，按浏览器请求的样子发最稳）。
    private func fetchDataWithHeaders(url: URL, headers: [String: String]) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        req.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await URLSession.shared.data(for: req)
    }

    private func fetchData(url: URL, userAgent: String? = nil) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        if let userAgent { req.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func fetchText(url: URL) async throws -> String {
        let data = try await fetchData(url: url)
        guard let text = String(data: data, encoding: .utf8) else { throw AmpError.http(0) }
        return text
    }

    /// 下到临时文件再由调用方换名（中途失败不留半截视频）。
    private func downloadToTemp(url: URL) async throws -> URL {
        let (tmpURL, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw AmpError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return tmpURL
    }

    // MARK: - 缓存文件

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("apple-animated-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(key: String, aspect: Aspect) -> URL {
        cacheDir.appendingPathComponent(safeKey(key) + aspect.suffix + ".mp4")
    }

    private func previewURL(key: String, aspect: Aspect) -> URL {
        cacheDir.appendingPathComponent(safeKey(key) + aspect.suffix + ".jpg")
    }

    /// 键里只有字母数字与 "-"（match 键是哈希，不含路径字符），再过一遍白名单防意外；
    /// ":" 与其他字符一律换成 "_"，文件名里不留冒号或斜杠。
    private func safeKey(_ key: String) -> String {
        key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
    }

    private static func shortHash(_ s: String) -> String {
        // 不引 CryptoKit 也能跑：FNV-1a 64 位，够当缓存键区分用（不作安全用途）。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// 超过上限或过期删最旧的（按竖版文件修改时间排），当前这张一定保留。
    private func pruneCache(keeping key: String) {
        let fm = FileManager.default
        let now = Date()
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let keepStem = safeKey(key)
        // 先清过期（> 30 天）且不是当前这张的：只按竖版文件遍历，一张专辑清一对。
        for file in files where file.lastPathComponent.hasSuffix("-p.mp4") {
            let stem = file.deletingPathExtension().lastPathComponent
            guard !stem.hasPrefix(keepStem) else { continue }
            if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               now.timeIntervalSince(mtime) > Self.cacheTTL {
                removePair(stem: String(stem.dropLast(2)))
            }
        }
        // 再按数量清：竖版超过 8 张删最旧。
        guard let remaining = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let portraits = remaining.filter { $0.lastPathComponent.hasSuffix("-p.mp4") }
        guard portraits.count > Self.maxCachedAlbums else { return }
        let sorted = portraits.sorted {
            (($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast))
        }
        for old in sorted.dropLast(Self.maxCachedAlbums) {
            let stem = old.deletingPathExtension().lastPathComponent.dropLast(2)
            removePair(stem: String(stem))
        }
    }

    private func removePair(stem: String) {
        for suffix in ["-p.mp4", "-s.mp4", "-p.jpg", "-s.jpg"] {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(stem + suffix))
        }
    }

    // MARK: - iOS 26 动态封面对象

    @available(iOS 26.0, *)
    private func makeArtwork(key: String, aspect: Aspect) -> MPMediaItemAnimatedArtwork {
        let url = fileURL(key: key, aspect: aspect)
        let previewFile = previewURL(key: key, aspect: aspect)
        return MPMediaItemAnimatedArtwork(
            artworkID: "lizi-apple-" + safeKey(key) + aspect.suffix,
            previewImageRequestHandler: { _ in
                guard let data = try? Data(contentsOf: previewFile) else { return nil }
                return UIImage(data: data)
            },
            videoAssetFileURLRequestHandler: { _ in
                FileManager.default.fileExists(atPath: url.path) ? url : nil
            })
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

// MARK: - 接线（集成步骤用，不改本文件以外的任何文件就能接）
//
// 在 NowPlayingCoordinator.swift 里接（以下行号以 2026-11-20 的版本为准）：
//
// 1. writeNowPlaying() 约第 95–108 行的路线 A 挂接之前，先问路线 B：
//      if #available(iOS 26.0, *), animatedArtworkEnabled,
//         let appleKey = AppleAnimatedArtworkProvider.shared.albumKey(for: track),
//         AppleAnimatedArtworkProvider.shared.isReady(key: appleKey) {
//          // 有真视频：竖版/方形各挂各的；挂上了就不再走路线 A 的同键挂接。
//          let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
//          if supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork),
//             let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: appleKey, aspect: .portrait) {
//              info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = art
//          }
//          if supported.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork),
//             let art = AppleAnimatedArtworkProvider.shared.artwork(forKey: appleKey, aspect: .square) {
//              info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = art
//          }
//      } else { …现有路线 A 的 if 块原样保留… }
//    注意：albumKey(for:) 在 Apple Music 以外平台的歌上是 match 键（歌手|专辑名哈希），
//    专辑解析是异步的，首次切歌时 key 存在但 isReady 为 false——此时不要等，直接走
//    路线 A；prepare 的回调里再补写一次（见第 2 步）。
//
// 2. fetchArtwork(for:) 约第 145–175 行，拿到 image 调
//    AnimatedArtworkManager.shared.prepare 之前，先并行调路线 B：
//      AppleAnimatedArtworkProvider.shared.prepare(for: track) { [weak self] ready in
//          guard let self, ready else { return }
//          Task { @MainActor in self.writeNowPlaying() }
//      }
//    prepare 回调 true = 竖版真视频已就绪，writeNowPlaying() 重跑一次即挂上真视频；
//    false = 无素材/失败，什么都不做（路线 A 的视频已在挂接，本歌继续用路线 A）。
//    prepare 内部已做去重与否定缓存，切歌快时不会重复拉；封面还没到货的歌（无 coverURL
//    分支）也可以调 prepare——匹配只用歌手+专辑名，不依赖封面。
//
// 3. 岛上（Live Activity）暂不接：扩展读不到主 App 的 Caches（无 App Groups），
//    岛扩展的 ContentState 目前只传封面 Data。要接岛上真视频，二选一：
//    (a) 配 App Group（需付费开发者账号 + 带 group 权限的 profile，与 kun 签名同款
//        blocker），把本文件的 cacheDir 改到共享容器，扩展端直接读文件；
//    (b) 扩展端自拉：把本文件也编进 LiziNativeLiveActivity target（project.yml 的
//        该 target sources 里加 Sources/LiziNative/AppleAnimatedArtwork.swift，
//        本文件只依赖 Foundation/MediaPlayer/UIKit + Track——Track 在 Models.swift，
//        扩展端需另传专辑 id/歌手/专辑名进 ContentState，prepare 在扩展进程内跑）。
//    在 (a)/(b) 落地前，岛上继续用静态封面 + 路线 A 的兜底逻辑，不动扩展现有行为。
//
// 4. 设置里不用加开关：路线 B 复用现有的「动画插图」开关（lizi.animatedArtwork，
//    默认开）；关 = 锁屏回静态图，路线 A 与 B 一起跳过。用户自己的开发者 token
//    复用现有的 Apple Music token 粘贴入口（lizi.applemusic.devtoken），不用新入口。
//    若用户提供了自己的 MusicKit token，整首播放与路线 B 共用它，互不冲突。
