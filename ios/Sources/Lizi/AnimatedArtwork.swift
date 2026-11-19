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
    /// 编码回调专用队列：render 在 workQueue 上等 done 信号，回调必须跑在别的队列，
    /// 否则 workQueue 自己等自己，死锁。
    private let encodeQueue = DispatchQueue(label: "lizi.animated-artwork.encode", qos: .utility)
    /// 主线程读写：最近一次请求的封面键。后台渲染开工前先确认还是它——
    /// 切歌快时旧歌的渲染直接跳过，不白烧 CPU，也不挡新歌的视频。
    private var currentKey: String?
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

    private init() {}

    /// 封面 URL → 缓存键（SHA256 前 16 位，稳定；同封面共用一个 artworkID、同一份视频）。
    static func key(forCoverURL url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("animated-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(key: String, aspect: Aspect) -> URL {
        cacheDir.appendingPathComponent(key + aspect.suffix + ".mp4")
    }

    /// 两个尺寸的视频都在磁盘上才算就绪（Caches 可能被系统清掉，只信文件不信内存）。
    func isReady(key: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(key: key, aspect: .portrait).path)
            && FileManager.default.fileExists(atPath: fileURL(key: key, aspect: .square).path)
    }

    /// 对一个封面准备动态视频。已就绪时立刻回调；否则后台渲染，完了在主线程回调。
    /// 渲染失败重试一次；两次都失败也回调——调用方用上一首的缓存兜底，
    /// 不要静默变回静态（第 12 轮第 20 件 03:33 硬性要求：每首歌都要动）。
    /// 注意：只做渲染与文件管理，不碰任何 iOS 26 的符号，26 以下调了也没事
    /// （调用方在 #available 里把关，这里不重复判断）。
    func prepare(cover: UIImage, key: String, onReady: @escaping () -> Void) {
        // 存归一化后的图：后面裁 preview 与渲染都按它算，EXIF 方向不会捣乱。
        let image = cover.normalizedOrientation()
        previewLock.withLock {
            previews[key] = image
            // 换了封面，旧键裁好的 preview 作废（同 key 下次用到再裁）。
            previewCache.removeValue(forKey: key + Aspect.portrait.suffix)
            previewCache.removeValue(forKey: key + Aspect.square.suffix)
        }
        currentKey = key
        if isReady(key: key) { lastGoodKey = key; onReady(); return }
        workQueue.async { [weak self] in
            guard let self else { return }
            // 开工前再确认一次：切歌快时旧歌的渲染直接跳过。
            let stillCurrent = DispatchQueue.main.sync { self.currentKey == key }
            guard stillCurrent else { return }
            var succeeded = false
            for _ in 1...2 {
                do {
                    try self.render(image: image, key: key, aspect: .portrait)
                    try self.render(image: image, key: key, aspect: .square)
                    succeeded = true
                    break
                } catch {
                    // 第一次失败就地重试一次；两次都失败才认栽。
                    continue
                }
            }
            if succeeded { self.pruneCache(keeping: key) }
            DispatchQueue.main.async {
                if succeeded { self.lastGoodKey = key }
                onReady()
            }
        }
    }

    /// 当前歌的视频不可用时拿什么兜底：最近一个渲染成功的键（上一首的缓存），
    /// 要求它不是当前键、且视频还在磁盘上。没有可兜底的就返回 nil（比如刚装好
    /// 第一首歌、视频还在渲染——那几秒只能先静态，等 onReady 回调补写）。
    func fallbackKey(for key: String) -> String? {
        guard let good = lastGoodKey, good != key, isReady(key: good) else { return nil }
        return good
    }

    /// 已就绪时返回可直接放进 nowPlayingInfo 的动态封面对象；iOS 26 以下永远返回 nil。
    /// 同一 key+尺寸只建一个对象，反复复用。
    func artwork(forKey key: String, aspect: Aspect) -> Any? {
        if #available(iOS 26.0, *) {
            guard isReady(key: key) else { return nil }
            let cacheKey = key + aspect.suffix
            if let cached = artworks[cacheKey] { return cached }
            let art = makeArtwork(key: key, aspect: aspect)
            artworks[cacheKey] = art
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
        return MPMediaItemAnimatedArtwork(
            artworkID: "lizi-" + key,
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
        let portraits = files.filter { $0.lastPathComponent.hasSuffix("-p.mp4")
            && !$0.lastPathComponent.hasPrefix(Self.defaultKey + "-") }
        guard portraits.count > Self.maxCachedSongs else { return }
        let sorted = portraits.sorted {
            (($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast))
        }
        for old in sorted.dropLast(Self.maxCachedSongs) {
            let stem = old.deletingPathExtension().lastPathComponent.dropLast(2)
            for suffix in ["-p.mp4", "-s.mp4"] {
                try? fm.removeItem(at: cacheDir.appendingPathComponent(String(stem) + suffix))
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
            ])
        guard writer.canAdd(input) else { throw RenderError.cannotAddInput }
        writer.add(input)
        guard let cgImage = image.cgImage else { throw RenderError.noCGImage }
        // cover-fit：封面铺满画面，居中裁掉多余边。
        let fit = max(size.width / image.size.width, size.height / image.size.height)
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
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: tmpURL)
            throw writer.error ?? RenderError.failed
        }
        // 先写临时文件再换名：中途失败不留半截视频。
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tmpURL, to: finalURL)
    }

    /// 一帧：把封面画进像素缓冲。Core Graphics 的 y 轴朝上，先翻转再按左上角坐标画。
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
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: rect)
        return buffer
    }

    private enum RenderError: Error {
        case cannotAddInput
        case noCGImage
        case timeout
        case failed
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
