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
/// - r29 task 2（2026-11-21，用户真机验证的 bug）：《最伟大的作品》专辑本身
///   有 editorialVideo（us/hk 1721454339 已验证），但跨平台匹配失败——网易/QQ
///   播时专辑名是简体「最伟大的作品」，us 店面搜到的是英文 "Greatest Works Of
///   Art"/"Jay Chou"，tw/hk 是繁体「最偉大的作品」/「周杰倫」；旧 matches()
///   只做全半角归一化、不转简繁也不认英文别名，双向包含全失败；且
///   albumIdBySearch 在首个店面搜到列表非空就直接 return nil，根本不试
///   tw/hk；于是记 route-b-no-match（7 天否定缓存）。本轮三处修：
///   (a) norm() 先繁转简（ICU Traditional-Simplified）；(b) 别名表双向展开
///   （歌手/专辑的中英文写法互认）；(c) 三个店面都试完再判无匹配，某店面
///   原词无结果时用别名英文词补查一次。匹配只认归一化后的歌手名/专辑名，
///   不认平台——7 个平台（网易、QQ、酷狗、汽水、波点、酷我、Apple Music）
///   给的格式（简体/繁体/英文、带书名号或不带）都要能配上。
/// - 旧否定缓存清理（r29 task 2）：negatives 只在进程内内存，不写盘（全仓
///   只有本文件三处引用：声明、读取、markNegative）；修完后 prepare(for:)
///   开头跑一次迁移（UserDefaults `lizi.routeb.matchv2.cleared` 标记 absent
///   就清 negatives、置标记），升级后第一次播不被旧结论挡住。7 天否定逻辑
///   本身保留，只在三个店面都试完、确实无匹配时才记。
/// - 有素材的专辑实测：IVE REVIVE+（1873882195）、Taylor Swift《Midnights》
///   （1649434996）、周杰伦《Greatest Works Of Art》（1721454339，us 店面）。
///   无素材的专辑实测：王菲《寓言》（966489223）、Album Leaf《In a Safe Place》
///   （15405970）、《Into the Blue Again》（183211887）——editorialVideo 字段
///   根本不存在，走路线 A。中文搜索也通（"周杰伦 最伟大的作品" 在 us 店面搜到
///   正确专辑排第一）。
/// - r30（2026-11-21，用户决定：路线 B 改用 Apple Music 的艺人/专辑 ID 去对，
///   能适配的全部适配）：名字匹配的别名表只有 11 组手写条目，表外歌手/专辑仍配不上，
///   改走 ISRC（国际标准录音编码，全球统一、不受语言影响）。
///   链路：Track.isrc → GET /v1/catalog/{sf}/songs?filter[isrc]=…&include=albums
///   → 逐首取其专辑 → 首个有 editorialVideo 的专辑才算命中 → 下载视频。
///   关键坑（VM 实测）：同一个 ISRC 可对应多首歌——TWK972201202（《最伟大的作品》）
///   在 us 返回 2 首，data[0] 是单曲版（专辑 1721448748，无视频），data[1] 才是
///   专辑版（1721454339，有视频）；只取 data[0] 会错判无视频，必须逐首试完。
///   ISRC 没有或查不到时回落 r29 名字匹配（ICU 简繁 + 别名表 + 三店面），
///   别名表与 7 天否定缓存逻辑原样保留。成功配上的 (albumId, storefront)
///   按 ISRC 键缓存（内存 + UserDefaults，30 天 TTL，上限 64 条），
///   清理入口见 clearRouteBCaches()（否定缓存与 ISRC 缓存一起清）。
///   7 平台 ISRC 能不能拿到（2026-11-21 VM 对真上游实测，非凭记忆）：
///   - Apple Music：能。catalog attributes.isrc（实测 TWK972201202 /
///     HKG732264813）；iTunes Search/Lookup API 全键列表里根本没有 isrc，
///     所以 Apple Music 的 ISRC 只走 catalog。r31 起 catalog 用三路 token
///     （已贴 > 缓存网页 > 现抠，见 AppleMusic.swift catalogToken），
///     无粘贴 token 也能走 catalog、拿到 ISRC（r31 断点 1 的根因修；
///     catalogSearch 还补了 Origin 头——网页 token 在官方 host 上无
///     Origin 会 401，VM 实测；专辑 id 从 attributes.url 解析，search
///     端点不回 relationships，VM 实测）。
///   - 网易：不能。搜索行与 weapi /v3/song/detail 全键列表均无 isrc。
///   - QQ：不能。DoSearchForQQMusicLite 搜索行与 get_song_detail_yqq 的
///     track_info 全键列表均无 isrc。
///   - 酷狗：不能。mobiles.kugou.com 搜索行全键无 isrc；详情 songinfo 走
///     gateway 需设备注册 + AES（VM 无法直调）；Folia 归一化亦无 isrc。
///   - 汽水：不能。VM 无法直调（设备注册 + ECDSA 签名）；base_info /
///     related_info / display_info / player_info 四块均无 isrc 字段；
///     Folia 与 Android 壳版服务均无 isrc。
///   - 波点：不能。搜索整包（3 首，含 mediaBasicInfo / audios）做
///     isrc 子串扫描，结果为无。
///   - 酷我：不能。search.kuwo.cn 搜索行整包做 isrc 子串扫描，结果为无；
///     www musicInfo 详情需 Hm_Iuvt_ token + DES Secret（VM 未直调），
///     m 站 songinfoandlrc 回 301 查询失败。
///   结论：ISRC 路实际只有 Apple Music 一家能走；其余 6 台拿不到 ISRC，
///   老实走名字路兜底，不编假 ISRC、不拿别家字段冒充。
///   回归（VM 实测）：《最伟大的作品》ISRC TWK972201202 → 专辑版
///   1721454339 有 editorialVideo（配上）；《海屿你》ISRC HKG732264813 →
///   专辑 1692508526（Single）无 editorialVideo，另一 Single 1895803820
///   直接查专辑也无 editorialVideo，仍走路线 A。
///   Token：仍走本文件现有的两路（用户已贴 token → 网页 token，401 回落），
///   与 AppleMusicAuth.developerToken() 同源（同一批 UserDefaults 键 +
///   同一套抠 token 正则）；不直接调 developerToken() 是因为它只回第一个
///   可用 token，用户 token 被 amp-api 拒时无法回落网页 token——没有另写
///   第三套取 token 逻辑，AppleMusicAuth.swift 本轮未改。
/// 缓存与回落：
/// - Caches/apple-animated-artwork/<key>-p.mp4 / -s.mp4（竖版 3:4 供锁屏、方形
///   1:1 备用），与路线 A 的 animated-artwork/ 目录分开；预览图同目录存
///   <key>-p.jpg / -s.jpg（previewFrame 模板按 720x960 / 720x720 取）。
/// - 上限 8 张专辑、TTL 30 天，超限删最旧；否定结果（无素材/匹配不上）只记内存
///   7 天，不写盘。任何一步失败 → prepare 回调 false，调用方走路线 A，绝不崩、
///   绝不返回半截文件（先下 tmp 再换名；下载后验 ftyp + 大小 > 100KB 才认）。
/// - r28：灵动岛已整个移除，本文件只供锁屏（主 App 进程内
///   MPNowPlayingInfoCenter），不碰任何扩展。
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
    /// r29 task 2 迁移标记：旧版否定缓存按错的匹配逻辑记的 route-b-no-match，
    /// 升级后第一次 prepare 必须清掉（见 migrateMatchV2IfNeeded）。bool
    /// 缺省为 false，正好表示“还没清过”。
    private static let matchV2ClearedKey = "lizi.routeb.matchv2.cleared"
    /// r30：ISRC → (albumId, storefront) 缓存的 UserDefaults 键（JSON：
    /// { ISRC: { "albumId": ..., "storefront": ..., "savedAt": ... } }）。
    /// 只记“配上过且当时有视频”的成功结论；ISRC 查不到 / 无视频不记，
    /// 由原有的 match 键否定缓存（route-b-no-match / no-video）兜底。
    private static let isrcAlbumCacheKey = "lizi.routeb.isrcalbums"
    private static let isrcAlbumCacheTTL: TimeInterval = 30 * 24 * 3600
    private static let isrcAlbumCacheMax = 64
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
    /// r30：ISRC → (albumId, storefront, 记入时间) 的内存镜像；落盘见
    /// isrcAlbumCacheKey。视频文件本身仍按 match 键（albumKey）存，ISRC
    /// 缓存只省“ISRC → song → album”的查找，不另起一套视频键（否则同一张
    /// 专辑经 ISRC 路与名字路会存两份视频）。
    private var isrcAlbums: [String: (albumId: String, storefront: String, date: Date)] = [:]
    private var isrcCacheLoaded = false
    /// 最近一次按 key 落定的路线 B 结论 lane（五个结论之一）：prepare 同 key
    /// 合并调用（第二首歌）回调时，按这个 lane 给那首歌补记一笔。
    private var lastConclusion: [String: String] = [:]
    /// 本次 resolve 里 amp-api 失败过的 key（token/网络/限流）：ampGet 全部
    /// 尝试耗尽时记入。resolve 据此把“查不到”与“没查成”分开——没查成按
    /// kind 记 lane（见 ampFailureLane），不记否定（瞬时问题，下次还查）；
    /// 只有确定“无匹配 / 无 editorialVideo”才记否定（r20 补）。
    private var ampFailedKeys: Set<String> = []
    /// 本次 resolve 里 amp-api 失败的种类（第 22 轮第 3 件，见 ampGet 分流）：
    /// token-expired / rate-limited / network / token-unavailable 四种之一。
    /// 调用方据此把失败记成对应的 lane，而不是都记 download-failed。
    private var ampFailureKind: [String: String] = [:]

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
        // r29 task 2：先跑匹配 v2 迁移——旧否定结论（按错的匹配逻辑记的）
        // 在第一次播时清掉，否则升级后第一首歌就被旧缓存挡住。
        migrateMatchV2IfNeeded()
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
    /// 第 21 轮第 1 件：入口与出口都落盘——Route B 的 token 抓取（2.4MB 首页
    /// + 3.3MB JS + 正则）是崩溃窗口里最重的单件活之一，它开始/结束在
    /// 哪一步，下次诊断要能直接看到。
    private func resolveAndDownload(track: Track, key: String) async -> Bool {
        DiagLog.shared.recordPlaybackStep("routeB resolve start key=\(key) track=\(track.title)")
        // 否定结果在有效期内：直接认栽，不重复查——但结论要重记一笔（r20 补）：
        // 否则 7 天内再播这首歌，诊断里看不到路线 B 的任何结论。
        lock.lock()
        let neg = negatives[key]
        ampFailedKeys.remove(key)
        ampFailureKind.removeValue(forKey: key)
        lock.unlock()
        if let neg, Date().timeIntervalSince(neg.date) < Self.negativeTTL {
            lock.lock(); lastConclusion[key] = neg.lane; lock.unlock()
            let short = neg.lane.replacingOccurrences(of: "route-b-", with: "")
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B \(short) (cached negative) track=\(track.title) artist=\(track.artist) album=\(track.album)",
                fields: ["lane": neg.lane, "platform": track.platform])
            return false
        }
        // r31：ISRC 为空时记一笔（route-b-no-isrc）——以前 ISRC 门直接跳过、
        // 日志里永远看不到“这首歌根本没走 ISRC 路”，断点 1 就是这么藏住的
        // （搜索走 iTunes 时 Track.isrc 恒为空）。这只是“本次没走 ISRC”
        // 的记录，不是结论：不进 lastConclusion、不记否定；是否命中 ISRC
        // 仍由下面的 isrc-hit / isrc-miss 记。放在否定缓存判断之后——
        // 已记否定的歌直接认栽，不重复刷这条。
        if track.isrc.isEmpty {
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B no ISRC on track, ISRC lookup skipped track=\(track.title) artist=\(track.artist) album=\(track.album)",
                fields: ["lane": "route-b-no-isrc", "platform": track.platform])
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
        // r30 ISRC 路（全平台）：Track.isrc 非空时先走 ISRC 精确匹配——
        // 同录音全球同一编码，不受歌手/专辑名的语言与简繁影响。命中（且
        // 该专辑有视频）直接用；没命中（无此 ISRC / 同 ISRC 的专辑都没
        // 视频 / 本次没查成）回落名字匹配，不记否定（否定只由名字路的
        // 确定性结论或 no-video 记，见下两处 markNegative；ISRC 本次没查成
        // 时 ampFailedKeys 已由 ampGet 置上，名字路同样查不成时走
        // amp-failure lane，不会误记 no-match）。
        if album == nil, !track.isrc.isEmpty {
            if let hit = await albumIdByISRC(track.isrc, key: key) {
                album = (hit.id, hit.storefront)
                editorial = hit.editorial
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B ISRC hit isrc=\(Self.normalizedISRC(track.isrc)) albumId=\(hit.id) storefront=\(hit.storefront) track=\(track.title)",
                    fields: ["lane": "route-b-isrc-hit", "isrc": Self.normalizedISRC(track.isrc), "albumId": hit.id, "storefront": hit.storefront, "platform": track.platform])
            } else {
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B ISRC miss, falling back to name match isrc=\(Self.normalizedISRC(track.isrc)) track=\(track.title) artist=\(track.artist) album=\(track.album)",
                    fields: ["lane": "route-b-isrc-miss", "isrc": Self.normalizedISRC(track.isrc), "platform": track.platform])
            }
        }
        if album == nil {
            album = await albumIdBySearch(artist: track.artist, album: track.album, key: key)
        }
        guard let album else {
            // 查不到分两种：amp-api 没查成（token/网络/限流）→ 按分流的 kind
            // 记 lane（token-expired / rate-limited / network-failed /
            // token-unavailable），不记否定；真查了没匹配上 → no-match，
            // 记否定（r20 补：之前两种都记 no-match，token 死掉时全锅都算到
            // “匹配不上”头上）。
            lock.lock()
            let ampFailed = ampFailedKeys.contains(key)
            lock.unlock()
            if ampFailed {
                let lane = ampFailureLane(for: key)
                let kind = ampFailureKind(for: key) ?? "network"
                lock.lock(); lastConclusion[key] = lane; lock.unlock()
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B amp-api failed kind=\(kind) album lookup inconclusive track=\(track.title) artist=\(track.artist) album=\(track.album)",
                    fields: ["lane": lane, "kind": kind, "platform": track.platform])
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
            // 同上：没查成（token/网络/限流）→ 按分流的 kind 记 lane，
            // 不记否定；真查了专辑无 editorialVideo → no-video，记否定。
            lock.lock()
            let ampFailed = ampFailedKeys.contains(key)
            lock.unlock()
            if ampFailed {
                let lane = ampFailureLane(for: key)
                let kind = ampFailureKind(for: key) ?? "network"
                lock.lock(); lastConclusion[key] = lane; lock.unlock()
                DiagLog.shared.recordLog(category: "apple-animated-artwork",
                    message: "route B amp-api failed kind=\(kind) editorialVideo lookup inconclusive albumId=\(album.id) storefront=\(album.storefront) track=\(track.title)",
                    fields: ["lane": lane, "kind": kind, "albumId": album.id, "storefront": album.storefront, "platform": track.platform])
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
            DiagLog.shared.recordPlaybackStep("routeB ready key=\(key) track=\(track.title)")
            DiagLog.shared.recordLog(category: "apple-animated-artwork",
                message: "route B ready albumId=\(album.id) storefront=\(album.storefront) track=\(track.title)",
                fields: ["lane": "route-b-ready", "albumId": album.id, "storefront": album.storefront, "platform": track.platform])
        } else {
            // r20：视频下载失败不记否定——下载失败多是瞬时网络/限流问题，
            // 记 7 天否定会把一首明明有真素材的专辑判死 7 天（进程内），
            // 下次 prepare 直接认栽、连重试的机会都没有；只有“无匹配 /
            // 专辑根本无 editorialVideo”这两种确定性结论才记否定（见上）。
            lock.lock(); lastConclusion[key] = "route-b-download-failed"; lock.unlock()
            DiagLog.shared.recordPlaybackStep("routeB fail key=\(key) track=\(track.title)")
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

    /// 公开：清掉进程内全部否定结论（7 天否定缓存）。供 r29 task 2 的升级
    /// 迁移与诊断调用；negatives 只在内存，不写盘，清完即无残留。
    func clearNegatives() {
        lock.lock()
        negatives.removeAll()
        lock.unlock()
    }

    /// r30 公开：清掉路线 B 的全部缓存结论——7 天否定缓存（clearNegatives）
    /// + ISRC → 专辑缓存（内存镜像与 UserDefaults 落盘一起清）。
    /// 供设置里的诊断清理或错配后手动清理调用；视频文件本身不在这里删
    /// （Caches 由 pruneCache 按 TTL/数量管，删错配结论后下次 prepare
    /// 会重新查 ISRC/名字并覆盖）。不碰 matchV2 迁移标记（它只表示
    /// “r29 升级迁移已跑过”，清掉会让旧否定结论在下次 prepare 时被
    /// 重新清一次——无害但没必要）。
    func clearRouteBCaches() {
        clearNegatives()
        clearISRCAlbumCache()
    }

    /// r30：只清 ISRC → 专辑缓存（内存 + 落盘）。clearRouteBCaches 调它；
    /// 单独调用于“只想重查 ISRC、不动否定结论”的诊断场景。
    func clearISRCAlbumCache() {
        lock.lock()
        isrcAlbums.removeAll()
        isrcCacheLoaded = true
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.isrcAlbumCacheKey)
    }

    /// r29 task 2 升级迁移：标记 absent = 还没清过旧否定结论 → 清一次并
    /// 置标记。prepare(for:) 开头调用；幂等，多次调用无副作用。只清
    /// “匹配修之前记的”旧结论——标记一旦置上，后续记的否定都是新逻辑
    /// 下的有效结论，不再动。
    private func migrateMatchV2IfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.matchV2ClearedKey) else { return }
        clearNegatives()
        UserDefaults.standard.set(true, forKey: Self.matchV2ClearedKey)
    }

    /// 本次 resolve 里 amp-api 失败的种类（ampGet 分流记的，四种之一；
    /// 没失败过返回 nil）。
    private func ampFailureKind(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return ampFailureKind[key]
    }

    /// amp-api 没查成时记的 lane（第 22 轮第 3 件）：按 kind 分流，
    /// token-expired / rate-limited / network-failed / token-unavailable
    /// 四种都是“没查成”，不记否定——token 失效尤其不能记 7 天否定
    /// （r20 已修，确认还在）：下次 prepare 照常重查，不会把一张有真素材
    /// 的专辑判死 7 天。只有“无匹配 / 专辑根本无 editorialVideo”
    /// 这两种确定性结论才记否定（见 resolveAndDownload 的 markNegative）。
    private func ampFailureLane(for key: String) -> String {
        switch ampFailureKind(for: key) ?? "network" {
        case "token-expired": return "route-b-token-expired"
        case "rate-limited": return "route-b-rate-limited"
        case "token-unavailable": return "route-b-token-unavailable"
        default: return "route-b-network-failed"
        }
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

    /// r30 ISRC → 专辑：GET /v1/catalog/{sf}/songs?filter[isrc]=…&include=albums。
    /// 同一个 ISRC 可对应多首歌（专辑版 + 单曲版 + 精选集收录），必须逐首取其
    /// 专辑、逐个查 editorialVideo，首个有真视频的专辑才算命中——只取 data[0]
    /// 会错配到无视频的单曲版（实测：TWK972201202 在 us 返回 2 首，data[0]
    /// 专辑 1721448748 无视频，data[1] 专辑 1721454339 有视频）。
    /// 返回 editorial 一并带回，调用方不再重复拉一次。命中后把 (albumId,
    /// storefront) 按 ISRC 缓存（30 天）；三店面都无视频 / 无此 ISRC 返回 nil，
    /// 调用方回落名字匹配。本次没查成（ampGet 抛错）时 ampFailedKeys 已由
    /// ampGet 置上，调用方按 amp-failure lane 记，不记否定。
    private func albumIdByISRC(_ rawISRC: String, key: String) async -> (id: String, storefront: String, editorial: [String: Any])? {
        let isrc = Self.normalizedISRC(rawISRC)
        guard !isrc.isEmpty else { return nil }
        // 1. 缓存命中（未过期）：直接用，但视频存在性仍由调用方现查一次
        //    （fetchEditorialVideo，1 次请求）再确认——缓存只省 ISRC →
        //    song → album 的查找，不替视频存在性背书。
        if let hit = isrcAlbumCached(isrc) {
            if let ed = await fetchEditorialVideo(albumId: hit.albumId, storefront: hit.storefront, key: key) {
                return (hit.albumId, hit.storefront, ed)
            }
            // 缓存的专辑现在查不到视频了（下架 / 接口抖动）：不直接判死，
            // 落到第 2 步现查一次——现查仍无视频才回落名字匹配。
            lock.lock()
            isrcAlbums.removeValue(forKey: isrc)
            lock.unlock()
            saveISRCAlbumCache()
        }
        // 2. 逐店面查 ISRC；同 ISRC 的歌逐首试其专辑的视频。
        for sf in Self.storefronts {
            guard let data = try? await ampGet(path: "/v1/catalog/\(sf)/songs?filter[isrc]=\(isrc)&include=albums&limit=10", key: key),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]], !list.isEmpty else { continue }
            for song in list {
                guard let rel = song["relationships"] as? [String: Any],
                      let albums = rel["albums"] as? [String: Any],
                      let albumList = albums["data"] as? [[String: Any]],
                      let albumId = albumList.first?["id"] as? String, !albumId.isEmpty else { continue }
                guard let ed = await fetchEditorialVideo(albumId: albumId, storefront: sf, key: key) else { continue }
                cacheISRCAlbum(isrc, albumId: albumId, storefront: sf)
                return (albumId, sf, ed)
            }
        }
        return nil
    }

    /// r30 ISRC 归一化：去连字符/空白、全大写；只有 12 位才认
    /// （CCXXXYYNNNNN：前 2 位国家码字母，中间 3 位注册码字母数字，
    /// 后 7 位年份 + 编号数字）。不合格返回 ""，调用方按“无 ISRC”
    /// 走名字路，不把脏数据发去 catalog 查。供 Track.from 与本文件共用。
    static func normalizedISRC(_ s: String) -> String {
        let cleaned = s.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == 12 else { return "" }
        let c = Array(cleaned)
        guard c[0].isLetter, c[1].isLetter,
              c[5].isNumber, c[6].isNumber, c[7].isNumber, c[8].isNumber,
              c[9].isNumber, c[10].isNumber, c[11].isNumber else { return "" }
        return cleaned
    }

    // MARK: - r30 ISRC → 专辑缓存（内存镜像 + UserDefaults 落盘，30 天 TTL）

    /// 读缓存（未过期才回；过期条目顺手删掉）。首次调用时从 UserDefaults
    /// 懒加载一次；清缓存（clearISRCAlbumCache）后 loaded 已置 true，
    /// 不会把刚清掉的盘上数据又读回来。
    private func isrcAlbumCached(_ isrc: String) -> (albumId: String, storefront: String)? {
        lock.lock()
        defer { lock.unlock() }
        if !isrcCacheLoaded {
            isrcCacheLoaded = true
            if let raw = UserDefaults.standard.data(forKey: Self.isrcAlbumCacheKey),
               let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: [String: Any]] {
                for (k, v) in obj {
                    guard let albumId = v["albumId"] as? String, !albumId.isEmpty,
                          let storefront = v["storefront"] as? String, !storefront.isEmpty,
                          let savedAt = v["savedAt"] as? TimeInterval else { continue }
                    isrcAlbums[k] = (albumId, storefront, Date(timeIntervalSince1970: savedAt))
                }
            }
        }
        guard let hit = isrcAlbums[isrc] else { return nil }
        guard Date().timeIntervalSince(hit.date) < Self.isrcAlbumCacheTTL else {
            isrcAlbums.removeValue(forKey: isrc)
            return nil
        }
        return (hit.albumId, hit.storefront)
    }

    /// 写一条缓存（内存 + 落盘；超 64 条删最旧）。
    private func cacheISRCAlbum(_ isrc: String, albumId: String, storefront: String) {
        lock.lock()
        isrcAlbums[isrc] = (albumId, storefront, Date())
        if isrcAlbums.count > Self.isrcAlbumCacheMax {
            let sorted = isrcAlbums.sorted { $0.value.date < $1.value.date }
            for old in sorted.dropLast(Self.isrcAlbumCacheMax) {
                isrcAlbums.removeValue(forKey: old.key)
            }
        }
        lock.unlock()
        saveISRCAlbumCache()
    }

    /// 落盘当前内存镜像：内部取一次锁快照（NSLock 不可重入，本函数不调
    /// 其它带锁方法）；UserDefaults 写在锁外做，避免持锁碰磁盘。
    private func saveISRCAlbumCache() {
        lock.lock()
        var obj: [String: [String: Any]] = [:]
        for (k, v) in isrcAlbums {
            obj[k] = ["albumId": v.albumId, "storefront": v.storefront,
                      "savedAt": v.date.timeIntervalSince1970]
        }
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        UserDefaults.standard.set(data, forKey: Self.isrcAlbumCacheKey)
    }

    /// 其他平台的歌：按 "歌手 专辑名" 在 amp-api 搜专辑，首个双向匹配的才算命中。
    /// 只比歌手 + 专辑名，不比歌名（同一专辑的歌共用一个动态封面；歌名不参与匹配，
    /// 免得单曲与专辑版同名不同盘时配错）。
    /// r29 task 2：(1) 三个店面（us/tw/hk）都试完再判无匹配——某店面搜到列表
    /// 但无一双向匹配时，不再直接 return nil，而是继续试下一个店面（旧逻辑
    /// 在 us 搜到英文版、tw/hk 是繁体版时，us 的非匹配就把整首歌判死了）；
    /// (2) 某店面原词搜不到结果（空列表）时，用别名展开后的英文词再查一次
    /// 该店面——只在无结果时补查，不多刷；请求本身失败（nil）不补查，换店面。
    private func albumIdBySearch(artist: String, album: String, key: String) async -> (id: String, storefront: String)? {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let albumName = album.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !albumName.isEmpty else { return nil }
        let aliasTerm = Self.aliasSearchTerm(artist: artist, album: albumName)
        for sf in Self.storefronts {
            var list = await searchAlbums(term: "\(artist) \(albumName)", storefront: sf, key: key)
            if let l = list, l.isEmpty, let aliasTerm {
                list = await searchAlbums(term: aliasTerm, storefront: sf, key: key)
            }
            guard let list else { continue }
            for item in list {
                guard let id = item["id"] as? String,
                      let attr = item["attributes"] as? [String: Any],
                      let name = attr["name"] as? String,
                      let itemArtist = attr["artistName"] as? String,
                      Self.matches(artist: artist, album: albumName, candidateArtist: itemArtist, candidateAlbum: name) else { continue }
                return (id, sf)
            }
            // 该店面搜到了专辑但没一个双向匹配：不直接判死，继续试下一个店面。
            // 三个店面都试完、无一匹配才返回 nil（循环结束后的 return nil）。
        }
        return nil
    }

    /// 单个店面搜专辑，返回原始列表。nil = 请求/解析失败（换店面，不补查）；
    /// 空数组 = 该店面确实无结果（可触发别名补查）。与 albumIdBySearch 的
    /// 匹配循环分开，便于只在“无结果”时补查一次。
    private func searchAlbums(term: String, storefront: String, key: String) async -> [[String: Any]]? {
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let data = try? await ampGet(path: "/v1/catalog/\(storefront)/search?types=albums&term=\(encoded)&limit=5", key: key),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [String: Any],
              let albums = results["albums"] as? [String: Any],
              let list = albums["data"] as? [[String: Any]] else { return nil }
        return list
    }

    /// 别名表：同一歌手 / 同一专辑的不同写法（简体 / 繁体 / 英文）视为同一个。
    /// 怎么加新条目：
    /// - 已有歌手/专辑多了个别名 → 往它那一组里加一个字符串；
    /// - 新歌手/专辑 → 新加一组 `["中文名", "繁體名", "English Name"]`；
    /// - 简繁同形的只写中文名 + 英文名即可（繁简归一在 norm() 里已做，
    ///   表里同时写简繁两形是为了 ICU 转换万一失效时仍能展开）。
    /// 匹配时双向展开：输入与候选各取本组全部写法逐一比对，任一命中即算命中。
    /// 注意：别名单独一个词可能很通用（如专辑 "Fantasy"），但 matches() 要求
    /// 歌手与专辑同时命中，歌手那一关挡住了误配，所以组里放通用英文名是安全的。
    private static let aliasGroups: [[String]] = [
        // 歌手
        ["周杰伦", "周杰倫", "Jay Chou"],
        ["林俊杰", "林俊傑", "JJ Lin"],
        ["蔡依林", "Jolin Tsai"],              // 蔡依林简繁同形
        ["五月天", "Mayday"],                  // 五月天简繁同形
        ["邓紫棋", "鄧紫棋", "G.E.M."],
        ["王菲", "Faye Wong"],                 // 王菲简繁同形
        // 专辑
        ["最伟大的作品", "最偉大的作品", "Greatest Works Of Art"],
        ["范特西", "Fantasy"],                 // 范特西简繁同形
        ["叶惠美", "葉惠美", "Ye Hui Mei"],
        ["十一月的萧邦", "十一月的蕭邦", "November's Chopin"],
        ["七里香", "Qi Li Xiang"],             // 七里香简繁同形
    ]

    /// 把一个名字展开成它所在别名组的全部写法（含自身）；不在任何组里就
    /// 只返回自身。组内按归一化后相等认人/认专辑（繁体输入先经 norm() 转简，
    /// 所以即使表里只写了简体也能展开；表里写全双形是双保险）。
    private static func expandedForms(of name: String) -> [String] {
        let n = norm(name)
        for group in aliasGroups where group.contains(where: { norm($0) == n }) {
            return group
        }
        return [name]
    }

    /// 别名补查词：把歌手/专辑名换成别名组里的英文写法（有才换），供某店面
    /// 原词搜不到结果时补查一次。两边都没有英文别名时返回 nil（不重复刷
    /// 同一个词）。英文写法优先——us 店面只认英文，中文词在它那里常搜不到。
    private static func aliasSearchTerm(artist: String, album: String) -> String? {
        func englishForm(of name: String) -> String? {
            let n = norm(name)
            return expandedForms(of: name).first(where: { form in
                norm(form) != n
                    && form.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")) != nil
            })
        }
        let enArtist = englishForm(of: artist)
        let enAlbum = englishForm(of: album)
        guard enArtist != nil || enAlbum != nil else { return nil }
        return "\(enArtist ?? artist) \(enAlbum ?? album)"
    }

    /// 归一化：r29 task 2 先繁转简（ICU Traditional-Simplified；返回 nil 时
    /// 回落原串，绝不崩），再走原有的去大小写 / 全半角 / 标点 / 空白。
    /// 繁简转换必须加在现有归一之前（任务书要求）：转换按整串做，拆散后
    /// 个别字可能转不准；去标点会把《》等书名号去掉，所以带书名号的输入
    /// （如汽水给的《最伟大的作品》）也能比上。
    private static func norm(_ s: String) -> String {
        let simplified = s.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? s
        let lowered = simplified.lowercased()
        return lowered.applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined() ?? lowered
    }

    /// 双向匹配：归一化后，歌手与专辑名各取「相等 或 一方包含另一方」。
    /// r29 task 2：歌手与专辑名各先按别名表展开（原串 + 组内全部写法），
    /// 任一组合命中即算命中——简体输入配英文/繁体候选、繁体输入配简体候选、
    /// 英文输入配中文候选都能过。匹配只认归一化后的歌手名/专辑名，不认平台。
    static func matches(artist: String, album: String, candidateArtist: String, candidateAlbum: String) -> Bool {
        func hit(_ a: String, _ b: String) -> Bool {
            for x in expandedForms(of: a) {
                for y in expandedForms(of: b) {
                    let na = norm(x), nb = norm(y)
                    guard !na.isEmpty, !nb.isEmpty else { continue }
                    if na == nb || na.contains(nb) || nb.contains(na) { return true }
                }
            }
            return false
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
    /// 第 22 轮第 3 件：失败分流——401/403、429、5xx/网络错、没 token
    /// 是四种不同结论，之前全部吞进同一个 "download-failed"，token 死掉
    /// 几天都看不出来；现在按 kind 记进 ampFailureKind，调用方按 kind
    /// 记 lane（见 ampFailureLane）。5xx 与 URLError/超时都算 network
    /// （瞬时问题，下次还查）；只有 401/403 全灭才算 token-expired。
    private func ampGet(path: String, key: String) async throws -> Data {
        guard let url = URL(string: "https://amp-api.music.apple.com" + path) else {
            throw AmpError.http(0)
        }
        var lastError: Error?
        var sawAuthFailure = false
        var sawRateLimit = false
        var attemptedAnyToken = false
        // 顺序：用户 token → 网页 token；每种最多试两次（第二次是刷新后重试）。
        let userToken = UserDefaults.standard.string(forKey: Self.userDevTokenKey) ?? ""
        var attempts: [(token: String, refreshWeb: Bool)] = []
        if !userToken.isEmpty { attempts.append((userToken, false)) }
        attempts.append((await webTokenForRequest(), true))
        for (index, attempt) in attempts.enumerated() {
            guard !attempt.token.isEmpty else { continue }
            attemptedAnyToken = true
            do {
                let (data, resp) = try await fetchDataWithHeaders(
                    url: url, headers: ["Authorization": "Bearer \(attempt.token)"])
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                if status == 401 || status == 403 {
                    sawAuthFailure = true
                    // 用户 token 被拒：换网页 token（下一轮）；网页 token 被拒：重抠一次再试。
                    if attempt.refreshWeb, index == attempts.count - 1 {
                        refreshWebTokenCache()
                        let fresh = await webTokenForRequest(forceRefresh: true)
                        if !fresh.isEmpty {
                            let (data2, resp2) = try await fetchDataWithHeaders(
                                url: url, headers: ["Authorization": "Bearer \(fresh)"])
                            if (resp2 as? HTTPURLResponse)?.statusCode == 200 { return data2 }
                            if (resp2 as? HTTPURLResponse)?.statusCode == 429 { sawRateLimit = true }
                        }
                    }
                    continue
                }
                if status == 429 { sawRateLimit = true }
                // 429（共用 token 被限流）与 5xx：不定论，直接当失败，不硬刷。
                throw AmpError.http(status)
            } catch let e as AmpError {
                lastError = e
            } catch {
                lastError = error
            }
        }
        // 全部尝试耗尽：按分流记 kind，调用方据此把“没查成”
        // 与“查了没有”分开记（r20 补）；不记否定，下次还查。
        // token 失效（401/403）只记 kind，不记否定（r20 已修，确认还在）：
        // 下次 prepare 照常重查，不会把一张有真素材的专辑判死 7 天。
        let kind: String
        if sawRateLimit { kind = "rate-limited" }
        else if sawAuthFailure { kind = "token-expired" }
        else if !attemptedAnyToken { kind = "token-unavailable" }
        else { kind = "network" }
        lock.lock()
        ampFailedKeys.insert(key)
        ampFailureKind[key] = kind
        lock.unlock()
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
        // 第 21 轮第 3 件：首页 2.4MB + bundle 3.3MB 全下下来转 String 再正则，
        // 是崩溃窗口里最重的单件活之一。加一道 8MB 上限（苹果改版导致 bundle
        // 膨胀时直接放弃、不把几十 MB 的字符串塞进内存），入口记一笔面包屑。
        DiagLog.shared.recordPlaybackStep("routeB token scrape start")
        let ua = Self.browserUserAgent
        guard let homeURL = URL(string: "https://music.apple.com"),
              let homeData = try? await fetchData(url: homeURL, userAgent: ua),
              homeData.count < 8_000_000,
              let home = String(data: homeData, encoding: .utf8) else { return nil }
        let bundlePattern = "/assets/index~[^\"'\\s]*\\.js"
        guard let bundleRegex = try? NSRegularExpression(pattern: bundlePattern),
              let match = bundleRegex.firstMatch(in: home, range: NSRange(home.startIndex..., in: home)),
              let bundleRange = Range(match.range, in: home) else { return nil }
        let bundlePath = String(home[bundleRange])
        guard let bundleURL = URL(string: "https://music.apple.com" + bundlePath),
              let jsData = try? await fetchData(url: bundleURL, userAgent: ua),
              jsData.count < 8_000_000,
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
// 3. r28：灵动岛已整个移除，岛上真视频的 (a)/(b) 两条路随岛作废，不再接。
//    本文件只供锁屏（主 App 进程内 MPNowPlayingInfoCenter）。
//
// 4. 设置里不用加开关：路线 B 复用现有的「动画插图」开关（lizi.animatedArtwork，
//    默认开）；关 = 锁屏回静态图，路线 A 与 B 一起跳过。用户自己的开发者 token
//    复用现有的 Apple Music token 粘贴入口（lizi.applemusic.devtoken），不用新入口。
//    若用户提供了自己的 MusicKit token，整首播放与路线 B 共用它，互不冲突。
