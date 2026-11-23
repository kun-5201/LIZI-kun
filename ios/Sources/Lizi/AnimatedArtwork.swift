import AVFoundation
import CryptoKit
import MediaPlayer
import UIKit

/// 第 12 轮第 20 件：锁屏动态封面（iOS 26+ 公开 API）。
///
/// 之前「第三方做不到」是 iOS 26 之前的结论。iOS 26 开放了 MPMediaItemAnimatedArtwork
/// （MediaPlayer，苹果文档 “Providing animated artwork for media items”，2026-11-15 更新），
/// 不用越狱、不用特殊 entitlement。Lizi 最低支持 16.2，所以全程用 #available(iOS 26.0)
/// 把关，26 以下照旧只有静态图。
///
/// 路线 A（已做）：拿静态封面在本地渲染一段无缝循环的缓慢推近视频（Ken Burns），
/// 对每首歌都管用；竖版 3:4 供锁屏铺满、方形 1:1 备用，按封面 URL 缓存复用
/// （artworkID 同封面共用，系统认作同一张封面）。
/// 路线 B（没做）：拉苹果真实动态素材（editorialVideo）——只有少数专辑有真素材，
/// 且 JWT 抠取是非官方路线，苹果改网页就断；路线 A 已覆盖每首歌，B 只是加分项。
/// vitrine 的 Fluid（轻微模糊 + 缓慢扭曲）也没做：逐帧高斯模糊会把渲染成本翻几倍，
/// 推近 + 轻移在锁屏上已经能读出动感；以后想加再在 render 里叠 CIFilter。
///
/// 不是路线（别走）：定时换静态 artwork 模拟动（会闪，系统还会节流 nowPlayingInfo 更新）、
/// 壁纸（没 API）、越狱插件（用户不越狱）。
final class AnimatedArtworkManager {
    static let shared = AnimatedArtworkManager()

    /// 没封面的歌用的键：所有没封面的歌共用同一份默认动态视频（默认图生成），
    /// 每首没封面的歌锁屏上也动起来。pruneCache 永远不删它。
    static let defaultKey = "default"

    /// 渲染规格：10 秒、24fps、无缝循环。系统要求短于 30 秒、不高于 60fps。
    private static let durationSeconds = 10.0
    private static let fps: Int32 = 24
    /// 缓存上限：8 首歌（每首 2 个视频，约 40MB，放 Caches 里，系统紧张时可清）。
    private static let maxCachedSongs = 8
    /// 渲染版本 v2（2026-11-19 倒置+恒蓝修复）：v1 的帧是上下颠倒且恒蓝的，
    /// 旧视频缓存在 Caches 里、键只认封面 URL，`prepare` 一旦 `isReady` 就永不
    /// 重渲染——不改文件名的话修复永远到不了用户手机。所以文件名带版本号，
    /// `init` 里删掉全部 v1 旧文件（见 `deleteLegacyCacheFiles`），强制重渲染。

    enum Aspect {
        case portrait  // 3:4，锁屏全屏铺满用
        case square    // 1:1，备用
        var size: CGSize {
            switch self {
            case .portrait: return CGSize(width: 720, height: 960)
            case .square: return CGSize(width: 720, height: 720)
            }
        }
        var suffix: String {
            switch self {
            case .portrait: return "-p"
            case .square: return "-s"
            }
        }
    }

    private let workQueue = DispatchQueue(label: "lizi.animated-artwork", qos: .utility)
    /// 方形渲染专用队列（第 22 轮第 3 件）：方形只是 1x1 备用，与竖版共用
    /// 一条串行队时，上一首的方形渲染会把下一首的竖版挡在队外——r21a 诊断
    /// 里竖版 ready 一次花了 31 秒，方形还在同一队里排着。两队并行，
    /// 各挡各的：下一首的竖版不等上一首的方形。
    private let squareQueue = DispatchQueue(label: "lizi.animated-artwork.square", qos: .utility)
    /// 编码回调专用队列：render 在 workQueue 上等 done 信号，回调必须跑在别的队列，
    /// 否则 workQueue 自己等自己，死锁。
    private let encodeQueue = DispatchQueue(label: "lizi.animated-artwork.encode", qos: .utility)
    /// 主线程读写：最近一次请求的封面键。后台渲染开工前先确认还是它——
    /// 切歌快时旧歌的渲染直接跳过，不白烧 CPU，也不挡新歌的视频。
    /// 第 21 轮第 3 件：原来后台读它要 `DispatchQueue.main.sync`——主线程
    /// 一旦被别的活占住（等 handler、解封面），编码回调每 24 帧就卡一次，
    /// 整个渲染跟着卡。改成 NSLock 读，任何线程直接读，不跳主线程；
    /// 写仍在 prepare（主线程调）里走同一把锁。
    private var currentKey: String?
    private let keyLock = NSLock()
    private func currentKeySnapshot() -> String? {
        keyLock.lock(); defer { keyLock.unlock() }; return currentKey
    }
    private func setCurrentKey(_ key: String?) {
        keyLock.lock(); currentKey = key; keyLock.unlock()
    }
    /// 主线程读写：最近一个渲染成功（视频已就绪）的键。当前歌的视频失败时，
    /// 锁屏挂它兜底——不要静默变回静态（第 12 轮第 20 件 03:33 要求）。
    private var lastGoodKey: String?
    /// preview 图 = 视频第一帧（= 静态封面本身）。主线程读写（handler 里读的那份走 previewLock）。
    private var previews: [String: UIImage] = [:]
    /// 按键裁好的 preview（key+suffix → 对应长宽比的图）。handler 可能在任意线程被调，
    /// 读写走 previewLock。
    private var previewCache: [String: UIImage] = [:]
    private let previewLock = NSLock()
    /// 已创建的动态封面对象（Any：nowPlayingInfo 的值本来就是 Any，
    /// 这样调用方不用在类型上碰 iOS 26 的符号；同实例复用，系统不会反复重认）。
    private var artworks: [String: Any] = [:]
    /// r55：artworks 字典的锁（与 previewLock/keyLock 同款）。
    private let artworksLock = NSLock()

    private init() { deleteLegacyCacheFiles() }

    /// 删掉 v1 渲染器留下的旧视频（`<key>-p.mp4` / `<key>-s.mp4`，无版本号）。
    /// v1 的帧上下颠倒且恒蓝（见 `makePixelBuffer` 注释），又因为缓存键只认
    /// 封面 URL，不清掉它们，`isReady` 会一直命中旧文件、修复永不生效。
    /// 只在单例第一次创建时跑一次：渲染是按启动隔离的，启动时刻不存在
    /// 正在写入的临时文件，删 `*.mp4` 里不带 `.v2.` 的就是安全的。
    private func deleteLegacyCacheFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "mp4" && !f.lastPathComponent.contains(".v2.") {
            try? fm.removeItem(at: f)
        }
    }

    /// 封面 URL → 缓存键（SHA256 前 16 位，稳定；同封面共用同一份视频；
    /// artworkID 还要再带尺寸后缀，见 `makeArtwork`）。
    static func key(forCoverURL url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private var cacheDir: URL {
        // r55：[0] 改回落（见 LocalFiles.directory 同款）。
        let dir = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("animated-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(key: String, aspect: Aspect) -> URL {
        cacheDir.appendingPathComponent(key + aspect.suffix + ".v2.mp4")
    }

    /// 两个尺寸的视频都在磁盘上才算就绪（Caches 可能被系统清掉，只信文件不信内存）。
    func isReady(key: String) -> Bool {
        isReady(key: key, aspect: .portrait) && isReady(key: key, aspect: .square)
    }

    /// 单个尺寸的视频在磁盘上才算该尺寸就绪（锁屏只用竖版：竖版好了就能挂，
    /// 不用等方形；r20 之前挂载与回落都认“两个都在”，方形一失败竖版也被拖死）。
    func isReady(key: String, aspect: Aspect) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(key: key, aspect: aspect).path)
    }

    /// 对一个封面准备动态视频。已就绪时立刻回调；否则后台渲染，完了在主线程回调。
    /// 竖版先行：锁屏只用竖版 3:4，竖版一好就先回调挂上，不等方形（方形只是
    /// 1x1 备用）；方形随后尽力补，失败只记日志，不影响已挂上的竖版。
    /// 渲染失败重试一次；两次都失败也回调——调用方用上一首的缓存兜底，
    /// 不要静默变回静态（第 12 轮第 20 件 03:33 硬性要求：每首歌都要动）。
    /// 注意：只做渲染与文件管理，不碰任何 iOS 26 的符号，26 以下调了也没事
    /// （调用方在 #available 里把关，这里不重复判断）。
    func prepare(cover: UIImage, key: String, onReady: @escaping () -> Void) {
        // 第 21 轮第 3 件：零尺寸图直接拒掉——0 宽/高进 normalizedOrientation
        // 的 UIGraphicsImageRenderer、再进 render 的 fit 除法（除零得 inf，
        // 矩形变 NaN），Core Graphics 拿到 NaN 矩形没有定义良好的行为，
        // 不能拿它赌锁屏不崩。记一笔就回静态兜底。
        guard cover.size.width > 0, cover.size.height > 0 else {
            DiagLog.shared.recordLog(category: "animated-artwork",
                message: "route A invalid image (zero size) key=\(key)",
                fields: ["lane": "route-a-invalid-image"])
            onReady()
            return
        }
        // 存归一化后的图：后面裁 preview 与渲染都按它算，EXIF 方向不会捣乱。
        let image = cover.normalizedOrientation()
        previewLock.withLock {
            previews[key] = image
            // 换了封面，旧键裁好的 preview 作废（同 key 下次用到再裁）。
            previewCache.removeValue(forKey: key + Aspect.portrait.suffix)
            previewCache.removeValue(forKey: key + Aspect.square.suffix)
        }
        setCurrentKey(key)
        DiagLog.shared.recordPlaybackStep("routeA prepare start key=\(key)")
        if isReady(key: key) { lastGoodKey = key; onReady(); return }
        // 第 22 轮第 3 件：记入队时间——竖版 ready 的 ms 是从块内开始算的，
        // 排队等了多久原来量不到；31 秒到底是队里等还是渲染本身慢，
        // 下次诊断拿这句 + ready 的 ms 一减就分得清（等超过 1 秒才记）。
        let enqueuedAt = Date()
        workQueue.async { [weak self] in
            guard let self else { return }
            let waitMs = Int(Date().timeIntervalSince(enqueuedAt) * 1000)
            if waitMs >= 1000 {
                DiagLog.shared.recordPlaybackStep("routeA queue wait key=\(key) ms=\(waitMs)")
            }
            // 开工前再确认一次：切歌快时旧歌的渲染直接跳过。
            let stillCurrent = self.currentKeySnapshot() == key
            guard stillCurrent else { return }
            let start = Date()
            // 竖版：已在磁盘就直接认，没在就渲染（最多两次）；失败记一条诊断——
            // r20 之前失败在这里 `catch { continue }` 静默吞掉，锁屏变静态且无记录。
            var portraitOK = self.isReady(key: key, aspect: .portrait)
            if !portraitOK {
                let r = self.renderWithRetry(image: image, key: key, aspect: .portrait)
                portraitOK = r.ok
                if r.cancelled {
                    // 第 22 轮第 3 件：切歌取消不是渲染失败——之前统一记
                    // "render failed"，用户快速连切几首歌时诊断里全是失败，
                    // 根本分不清是真坏还是切走了。现在单独记 cancelled。
                    DiagLog.shared.recordPlaybackStep("routeA render cancelled key=\(key) aspect=portrait ms=\(r.ms)")
                } else {
                    DiagLog.shared.recordPlaybackStep("routeA render \(portraitOK ? "ok" : "fail") key=\(key) aspect=portrait ms=\(r.ms) attempts=\(r.attempts)\(portraitOK ? "" : " err=\(r.lastError ?? "-")")")
                    if !portraitOK {
                        DiagLog.shared.recordLog(category: "animated-artwork",
                            message: "route A portrait render failed key=\(key) attempts=\(r.attempts) ms=\(r.ms) err=\(r.lastError ?? "-") fallback=\(self.fallbackKey(for: key) ?? "none")",
                            fields: ["lane": "route-a-render-failed", "aspect": "portrait", "attempts": r.attempts, "ms": r.ms, "error": r.lastError ?? "", "fallback": self.fallbackKey(for: key) ?? ""])
                    } else if r.ms > 15_000 {
                        // 单轮渲染超过 15 秒：记慢渲染（正常几秒到二十秒，
                        // 31 秒那次就是这档；attempts=2 说明第一轮失败后重试
                        // 才成，attempts=1 说明单轮本身就慢）。
                        DiagLog.shared.recordLog(category: "animated-artwork",
                            message: "route A portrait render slow key=\(key) ms=\(r.ms) attempts=\(r.attempts)",
                            fields: ["lane": "route-a-render-slow", "aspect": "portrait", "ms": r.ms, "attempts": r.attempts])
                    }
                }
            }
            if portraitOK {
                // 竖版好了：先记为最近可用的兜底，再回调挂上（不等方形）。
                DispatchQueue.main.async {
                    self.lastGoodKey = key
                    onReady()
                }
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                DiagLog.shared.recordLog(category: "animated-artwork",
                    message: "route A portrait ready key=\(key) ms=\(ms)",
                    fields: ["lane": "route-a-ready", "ms": ms])
            } else {
                DispatchQueue.main.async { onReady() }
            }
            // 方形改走独立的 squareQueue（见 squareQueue 注释）：方形只是
            // 1x1 备用，当前歌已经不是这首就别再烧；是这首也只在自己的队里
            // 跑，不占竖版队列、下一首的竖版不用等它。
            self.squareQueue.async { [weak self] in
                guard let self else { return }
                guard self.currentKeySnapshot() == key else { return }
                // 方形尽力而为：失败只记日志，不影响已挂上的竖版；成功再回调一次
                // （调用方补挂 1x1 键），顺带清缓存。
                if !self.isReady(key: key, aspect: .square) {
                    let r = self.renderWithRetry(image: image, key: key, aspect: .square)
                    if r.ok {
                        DiagLog.shared.recordPlaybackStep("routeA render ok key=\(key) aspect=square ms=\(r.ms) attempts=\(r.attempts)")
                        self.pruneCache(keeping: key)
                        DispatchQueue.main.async { onReady() }
                    } else if r.cancelled {
                        DiagLog.shared.recordPlaybackStep("routeA render cancelled key=\(key) aspect=square ms=\(r.ms)")
                    } else {
                        DiagLog.shared.recordPlaybackStep("routeA render fail key=\(key) aspect=square ms=\(r.ms) attempts=\(r.attempts) err=\(r.lastError ?? "-")")
                        DiagLog.shared.recordLog(category: "animated-artwork",
                            message: "route A square render failed key=\(key) attempts=\(r.attempts) ms=\(r.ms) err=\(r.lastError ?? "-")",
                            fields: ["lane": "route-a-render-failed", "aspect": "square", "attempts": r.attempts, "ms": r.ms, "error": r.lastError ?? ""])
                    }
                } else {
                    self.pruneCache(keeping: key)
                }
            }
        }
    }

    /// 单个尺寸渲染，最多两次（第一次失败就地重试一次）；返回是否成功、
    /// 是不是切歌取消、最后一次失败的原因、尝试次数与总耗时。
    /// 取消（切歌导致 currentKey 变了）不重试：新歌的渲染已经在队里排着，
    /// 旧歌再烧一轮纯属浪费，重试只会把新歌的视频往后拖。
    /// 第 22 轮第 3 件：之前失败原因直接吞掉（`catch { continue }`），
    /// 诊断里只有一句 "render failed"、不知道是写不进文件、编码器起不来
    /// 还是超时——现在把每次失败的 error 描述与耗时都带出来，下次诊断
    /// 直接读 err= 就知道是哪种失败；31 秒慢渲染也一样，attempts=2
    /// 说明第一轮失败后重试才成，attempts=1 说明单轮本身就慢。
    private func renderWithRetry(image: UIImage, key: String, aspect: Aspect) -> (ok: Bool, cancelled: Bool, lastError: String?, attempts: Int, ms: Int) {
        let start = Date()
        var lastError: String?
        var attempts = 0
        for _ in 1...2 {
            attempts += 1
            do {
                try render(image: image, key: key, aspect: aspect)
                return (true, false, nil, attempts, Int(Date().timeIntervalSince(start) * 1000))
            } catch RenderError.cancelled {
                return (false, true, nil, attempts, Int(Date().timeIntervalSince(start) * 1000))
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                continue
            }
        }
        return (false, false, lastError, attempts, Int(Date().timeIntervalSince(start) * 1000))
    }

    /// 当前歌的视频不可用时拿什么兜底：最近一个竖版渲染成功的键（上一首的缓存），
    /// 要求它不是当前键、且竖版视频还在磁盘上。没有可兜底的就返回 nil（比如刚装好
    /// 第一首歌、视频还在渲染——那几秒只能先静态，等 onReady 回调补写）。
    func fallbackKey(for key: String) -> String? {
        guard let good = lastGoodKey, good != key, isReady(key: good, aspect: .portrait) else { return nil }
        return good
    }

    /// 已就绪时返回可直接放进 nowPlayingInfo 的动态封面对象；iOS 26 以下永远返回 nil。
    /// 同一 key+尺寸只建一个对象，反复复用。按尺寸认就绪（竖版好了就能挂，
    /// 不用等方形——r20 之前这里认“两个都在”，方形缺失会连竖版一起拒掉）。
    func artwork(forKey key: String, aspect: Aspect) -> Any? {
        if #available(iOS 26.0, *) {
            guard isReady(key: key, aspect: aspect) else { return nil }
            let cacheKey = key + aspect.suffix
            // r55：artworks 字典加锁（previews/previewCache 有 previewLock、
            // currentKey 有 keyLock，artworks 没有；调用方虽全在主线程，
            // 但它是共享可变状态，加同一套 NSLock 防御，不改行为）。
            // 读与写各锁一次；makeArtwork 在锁外建（重活不占锁）。
            if let cached = artworksLock.withLock({ artworks[cacheKey] }) { return cached }
            let art = makeArtwork(key: key, aspect: aspect)
            artworksLock.withLock { artworks[cacheKey] = art }
            return art
        } else {
            return nil
        }
    }

    /// 一个对象只服务一个尺寸的视频：竖版对象给 3:4 的键，方形对象给 1:1 的键。
    /// 两个 handler 都是 async 直接返回值（苹果文档原文示例）：
    /// preview 返回视频第一帧，视频返回本地文件 URL（已提前渲染好，不用现下载，
    /// 30 秒超时碰不到）；拿不到就返回 nil，系统回落到静态图。
    @available(iOS 26.0, *)
    private func makeArtwork(key: String, aspect: Aspect) -> MPMediaItemAnimatedArtwork {
        let url = fileURL(key: key, aspect: aspect)
        let cacheKey = key + aspect.suffix
        // artworkID 必须按尺寸区分：之前竖版和方形共用 "lizi-<key>"，系统可能
        // 把两个不同视频当成同一张封面去重。ID 里带上尺寸后缀，各是各的。
        return MPMediaItemAnimatedArtwork(
            artworkID: "lizi-" + cacheKey,
            previewImageRequestHandler: { [weak self] _ in
                self?.croppedPreview(forKey: cacheKey, aspect: aspect)
            },
            videoAssetFileURLRequestHandler: { _ in url })
    }

    /// preview 图：视频第一帧裁成对应长宽比（方形键 1:1、竖版键 3:4）。
    /// 文档原话：长宽比差太多系统可能拒收——封面多是方的，竖版键必须裁。
    /// 只裁一次，后面复用；handler 可能在任意线程被调，读写加锁。
    private func croppedPreview(forKey cacheKey: String, aspect: Aspect) -> UIImage? {
        previewLock.withLock {
            if let cached = previewCache[cacheKey] { return cached }
            let key = String(cacheKey.dropLast(2))
            guard let base = previews[key] else { return nil }
            guard let cg = base.cgImage else { return base }
            let targetAspect = aspect.size.width / aspect.size.height
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let imgAspect = w / h
            let crop: CGRect
            if imgAspect > targetAspect {
                let cw = h * targetAspect
                crop = CGRect(x: (w - cw) / 2, y: 0, width: cw, height: h)
            } else {
                let ch = w / targetAspect
                crop = CGRect(x: 0, y: (h - ch) / 2, width: w, height: ch)
            }
            guard let cropped = cg.cropping(to: crop) else { return base }
            let image = UIImage(cgImage: cropped, scale: base.scale, orientation: .up)
            previewCache[cacheKey] = image
            return image
        }
    }

    /// 缓存超过上限时删最旧的（按竖版文件的修改时间排），新歌那份一定保留；
    /// 默认键（没封面的歌共用）永远不删——它是所有没封面歌的兜底。
    private func pruneCache(keeping key: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let portraits = files.filter { $0.lastPathComponent.hasSuffix("-p.v2.mp4")
            && !$0.lastPathComponent.hasPrefix(Self.defaultKey + "-") }
        guard portraits.count > Self.maxCachedSongs else { return }
        let sorted = portraits.sorted {
            (($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast))
        }
        for old in sorted.dropLast(Self.maxCachedSongs) {
            // 文件名 <key>-p.v2.mp4：去掉 "-p.v2.mp4"（9 个字符）得 key。
            let stem = String(old.lastPathComponent.dropLast("-p.v2.mp4".count))
            for suffix in ["-p.v2.mp4", "-s.v2.mp4"] {
                try? fm.removeItem(at: cacheDir.appendingPathComponent(stem + suffix))
            }
        }
    }

    // MARK: - 本地渲染（纯 AVFoundation，不碰 iOS 26 的符号）

    /// 一张封面渲染成一段无缝循环视频：缩放 1.0 → 1.10 → 1.0（正弦往返，
    /// 首尾同帧、首尾速度都为 0，所以循环接缝看不出来），再加轻微平移。
    private func render(image: UIImage, key: String, aspect: Aspect) throws {
        let size = aspect.size
        let finalURL = fileURL(key: key, aspect: aspect)
        let tmpURL = cacheDir.appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: tmpURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoExpectedSourceFrameRateKey: Self.fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                // 像素缓冲要进 CGContext 画：声明 CG 兼容，CoreVideo 按 CG 可用的
                // 对齐方式分配，否则个别设备上可能拿到 CG 写不进去的缓冲。
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw RenderError.cannotAddInput }
        writer.add(input)
        guard let cgImage = image.cgImage else { throw RenderError.noCGImage }
        // cover-fit：封面铺满画面，居中裁掉多余边。
        // 第 21 轮第 3 件：fit 除零得 inf、矩形变 NaN 再画进像素缓冲是没有
        // 定义良好的行为的；零尺寸图在 prepare 里已拒，这里再守一道
        // （prepare 之后 image 不可能变，但 render 是独立入口，别信上游）。
        guard image.size.width > 0, image.size.height > 0 else { throw RenderError.noCGImage }
        let fit = max(size.width / image.size.width, size.height / image.size.height)
        guard fit.isFinite, fit > 0 else { throw RenderError.failed }
        let drawW = image.size.width * fit, drawH = image.size.height * fit
        let baseRect = CGRect(x: (size.width - drawW) / 2, y: (size.height - drawH) / 2,
                              width: drawW, height: drawH)
        let totalFrames = Int(Self.durationSeconds * Double(Self.fps))
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let done = DispatchSemaphore(value: 0)
        var frameIndex = 0
        input.requestMediaDataWhenReady(on: encodeQueue) { [weak self] in
            guard let self else { done.signal(); return }
            while input.isReadyForMoreMediaData {
                // r20：切歌取消——渲染是串行队列里最耗时的一段（竖版+方形
                // 各 240 帧），旧歌的渲染跑满全程才会轮到新歌，锁屏就一直
                // 挂着上一首的视频。每 12 帧（约半秒）看一次 currentKey，
                // 歌已经切走了就地取消，不等跑完、也不重试（见 renderWithRetry）。
                // 第 22 轮第 3 件：24 帧改 12 帧——单帧慢的时候（31 秒那次
                // 每帧约 130ms）取消要等 3 秒才发现，12 帧约 1.5 秒；
                // 方形已拆到独立队列，竖版队里只剩竖版，取消越快新歌越早开工。
                // r21a：读 currentKey 走 NSLock（currentKeySnapshot），不再
                // DispatchQueue.main.sync——主线程被别的活占住时编码回调
                // 不再跟着卡（见 currentKey 注释）。
                if frameIndex % 12 == 0, frameIndex > 0,
                   self.currentKeySnapshot() != key {
                    writer.cancelWriting()
                    done.signal()
                    return
                }
                if frameIndex >= totalFrames {
                    input.markAsFinished()
                    writer.finishWriting { done.signal() }
                    return
                }
                let t = Double(frameIndex) / Double(totalFrames - 1)  // 0...1
                let zoom = 1.0 + 0.10 * sin(.pi * t)
                let panX = 8.0 * sin(2 * .pi * t)
                let panY = 5.0 * sin(2 * .pi * t + .pi / 3)
                let w = baseRect.width * zoom, h = baseRect.height * zoom
                let rect = CGRect(x: baseRect.midX - w / 2 + panX,
                                  y: baseRect.midY - h / 2 + panY, width: w, height: h)
                guard let pixelBuffer = self.makePixelBuffer(adaptor: adaptor, size: size,
                                                             cgImage: cgImage, rect: rect) else {
                    writer.cancelWriting()
                    done.signal()
                    return
                }
                adaptor.append(pixelBuffer,
                               withPresentationTime: CMTime(value: CMTimeValue(frameIndex),
                                                            timescale: Self.fps))
                frameIndex += 1
            }
        }
        // 渲染 240 帧 720p 正常几秒到二十秒；2 分钟还没完就放弃，别卡住队列。
        guard done.wait(timeout: .now() + 120) == .success else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmpURL)
            throw RenderError.timeout
        }
        if writer.status == .cancelled {
            // 切歌取消（见上面帧循环里的检查）：不留半截文件，不重试。
            try? FileManager.default.removeItem(at: tmpURL)
            throw RenderError.cancelled
        }
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: tmpURL)
            throw writer.error ?? RenderError.failed
        }
        // 先写临时文件再换名：中途失败不留半截视频。
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
    }

    /// 一帧：把封面画进像素缓冲。
    ///
    /// 2026-11-19 倒置+恒蓝修复（v2），两处都是这一函数里的错，别处没动：
    ///
    /// 1. 恒蓝——bitmapInfo 缺了 `byteOrder32Little`。像素缓冲是
    ///    `kCVPixelFormatType_32BGRA`，内存里每个像素是 [B,G,R,A]；只写
    ///    `premultipliedFirst` 时 Core Graphics 默认按大端写 [A,R,G,B]，
    ///    编码器再按 BGRA 读回去，解出来是 R'=G、G'=R、B'=A=255、A'=B——
    ///    每个不透明像素的蓝色都被钉死在 255，整张封面恒蓝（真封面 FLOWER
    ///    平均色 (94,55,39) 会被写成 (55,94,255)，100% 像素 B==255，
    ///    见 verification/r19-artwork.cjs 的模拟数据）。修法就是补上
    ///    `byteOrder32Little`，让 CG 按 [B,G,R,A] 写，解码后与原图恒等。
    ///
    /// 2. 倒置——之前这里 `translateBy(0, 高) + scaleBy(1, -1)` 再画。
    ///    这套翻转是「位图 → CGImage → UIKit 视图」那条链的修正，不适用
    ///    于「像素缓冲内存 → H.264 编码器」这条链：编码器按内存行序
    ///    （首行即帧顶行）直接读，`CGContext.draw(cgImage)` 本来就把图
    ///    顶行写进首行，手动再翻一次等于倒过来（对照：ikyle.me 的
    ///    BGRA→H.264 导出器同样不翻转直接画，输出方向正确；翻转版在
    ///    真机锁屏全屏上就是用户看到的倒置）。修法：删掉翻转，直接画。
    ///    注意 rect 的数学不用动：cover-fit 矩形是中心对称的，翻不翻转
    ///    可见行集合相同；Ken Burns 的 panY 只是正弦漂移方向反一下，
    ///    幅度（±5px）与循环接缝都不变。
    ///
    /// 另外先涂黑底：池子里的缓冲可能带上一段视频的残留像素，Ken Burns
    ///    在 zoom=1.0 的首尾帧会留几像素没画到的边（pan ±5px），不涂黑
    ///    那些边会闪旧画面。
    private func makePixelBuffer(adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                 size: CGSize, cgImage: CGImage, rect: CGRect) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.draw(cgImage, in: rect)
        return buffer
    }

    /// 第 22 轮第 3 件：失败原因要进诊断（见 renderWithRetry），
    /// 每种错误给一句能读的描述；writer.error 原样抛时用 AVFoundation
    /// 自己的描述，不经过这里。
    private enum RenderError: Error, LocalizedError {
        case cannotAddInput
        case noCGImage
        case timeout
        case failed
        /// 切歌导致当前渲染作废（currentKey 已变）：renderWithRetry 不重试。
        case cancelled
        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "AVAssetWriter cannot add video input"
            case .noCGImage: return "cover has no CGImage / zero size"
            case .timeout: return "render timed out after 120s"
            case .failed: return "AVAssetWriter failed (see writer.error)"
            case .cancelled: return "cancelled (track changed)"
            }
        }
    }
}

private extension UIImage {
    /// 下载的 JPEG 可能带 EXIF 方向：cgImage 不认方向，直接画会歪。
    /// 先画一张朝上的新图，后面全按它算。
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension URL {
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
