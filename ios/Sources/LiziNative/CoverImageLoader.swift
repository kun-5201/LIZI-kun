import SwiftUI
import UIKit

/// 原生封面取图：进程内代理 → 直链 → 默认占位（三级兜底，P3-D）。
///
/// 链路（照抄锁屏已有的做法，见 `NowPlayingCoordinator`：进程内合成 `HttpRequest` 直调
/// `Proxies.proxyImage`，**不走 HTTP 回环、不复活 LocalHttpServer**；
/// `Proxies.swift` 本身一行没改，只在这里包一层薄封装）：
/// 1. 代理：`/api/img`（白名单 + 各家 Referer 绕防盗链，含 r15 的
///    `.mzstatic.com`；代理 403/502 时记诊断，不拦直链）。
/// 2. 直链：`URLSession` 直接拉原地址（个别不上白名单的图床、代理挂了时
///    的兜底；防盗链严格的图床这一步会空，由调用方占位）。
/// 3. 占位：两步都失败返回 `nil`，调用方显示默认图（白色底 + 音符，
///    绝不用 ♪ 冒充封面本身）。
///
/// 在飞任务共享（第 20 轮）：同一 URL 在一次启动里只拉一次，且取图跑在
/// detached 任务里——调用方的 `.task(id:)` 取消（视图滚走、切歌）只取消
/// 等待，不取消拉图本身；拉完进缓存，下次出现直接命中。旧代码里每次视图
/// 消失都把在飞的代理请求一并取消（-999），封面永远拉不到、一直回默认图。
///
/// r36（第⑥件，用户 2026-11-21 21:20「全站封面全白」）：根因两半——
/// ① 搜索腿封面字段映射漏（QQ qqTrack 只读 album.mid，顶层 albumMid 行
/// 封面恒为空；酷狗 mobilecdn 行本身无封面字段，但应用内搜索走网关/
/// complexsearch 行带 trans_param.union_cover，见 FoliaKugou.coverOf）；
/// ② 本链路单次尝试永不重试（见 ProxyImageView）：真机上几十张封面同时
/// 起取图，6s 超时 / 代理 502 / 门排队超时撞上一次就永久占位。
/// 修法：映射补齐（QQ.swift）+ ProxyImageView 最多 3 次重试；占位本身
/// 改深色（CoverImageView.swift），加载失败不再看着像没数据。
///
/// 内存缓存：同一 URL 在一次启动里只拉一次（`NSCache`，约 50MB 上限，
/// 封面图本身不大）；跨启动的持久化走磁盘缓存（r48-11：`DiskCache`，
/// 封面 + 歌词 + 音频信息共用 16GB 池，见 DiskCache.swift）。
actor CoverImageLoader {
    static let shared = CoverImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    /// 在飞的取图任务（第 20 轮）：同一 URL 只拉一次；detached 任务不继承
    /// 调用方的取消，视图消失也不停。
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private init() {
        cache.totalCostLimit = 50 * 1024 * 1024
        cache.countLimit = 200
    }

    /// 取一张封面的 `UIImage`；三级都失败返回 `nil`（调用方显示占位）。
    /// 调用方取消等待时抛 CancellationError，但拉图本身继续跑完、进缓存。
    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        // r48-11：磁盘缓存优先——上次加载过直接读本地，不联网。
        if let data = DiskCache.data(kind: .cover, key: DiskCache.coverKey(for: url)),
           let img = UIImage(data: data) {
            store(img, for: url)
            return img
        }
        if let running = inFlight[url] { return await running.value }
        let task = Task.detached {
            let (img, data) = await CoverImageLoader.fetchUncached(url: url)
            await CoverImageLoader.shared.noteFinished(img, data: data, for: url)
            return img
        }
        inFlight[url] = task
        return await task.value
    }

    /// 在飞任务收尾（无论成功失败都清 inFlight；成功才进缓存）。
    private func noteFinished(_ image: UIImage?, data: Data?, for url: URL) {
        if let image { store(image, for: url) }
        // r48-11：联网取图成功才写盘（失败不写，不缓存坏数据）。
        if let data { DiskCache.store(data, kind: .cover, key: DiskCache.coverKey(for: url)) }
        inFlight[url] = nil
    }

    /// 进程内代理 → 直链（不抛错；两步都失败返回 `nil`）。
    /// 进程内代理 → 直链（不抛错；两步都失败返回 `(nil, nil)`）。
    private static func fetchUncached(url: URL) async -> (UIImage?, Data?) {
        // 1) 进程内代理（Proxies.proxyImage：白名单 + Referer + https 升级）。
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": url.absoluteString],
                                   headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status),
           let image = UIImage(data: proxyResp.body) {
            return (image, proxyResp.body)
        }
        // 2) 直链兜底（r24：走 Proxies.directImageData——同一个门、6s 上限、
        // 入口 https 归一；旧写法 URLSession.shared.data(from:) 默认 60s，
        // 代理死透后直链再等 60s，一张图最坏 100s 才占位）。
        if let data = await Proxies.directImageData(url),
           let image = UIImage(data: data) {
            return (image, data)
        }
        // 直链也失败：返回 nil，调用方占位，不抛错、不编图。
        return (nil, nil)
    }

    private func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// 代理封面图（`AsyncImage` 的替代：直连封面在个别上游会空白占位）。
///
/// 用法与 `AsyncImage(url:)` 的 phase 版对应：有图时 `resizable +
/// scaledToFill` 铺满调用方给的 frame；加载中 / 失败 / 无 URL 时显示
/// 调用方传的 `placeholder`（各调用点原来的占位原样保留，不改视觉）。
/// URL 变化时旧图先留着（不闪白），新图到了再换；URL 变空时回占位。
/// r36（第⑥件）：失败重试——旧写法一次拿不到就永远占位（单次 6s 超时 /
/// 代理 502 / 门排队超时都直接判死刑，视图不重建就不重试；真机上几十张
/// 封面同时起取图，尾部请求很容易撞上超时，就是「全站封面全白」的
/// 另一半根因，另一半是搜索腿封面字段映射，见 QQ.swift qqTrack）。
/// 最多 3 次（首试 + 2 次重试，间隔 0.5s / 1.5s）；URL 变了旧任务取消、
/// 新任务重开；成功一次即停；每次都走 CoverImageLoader（进程内缓存 +
/// 在飞去重），重试不重复发请求。
struct ProxyImageView<Placeholder: View>: View {
    let url: URL?
    let placeholder: Placeholder

    @State private var uiImage: UIImage?

    init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else {
                uiImage = nil
                return
            }
            var attempt = 0
            while !Task.isCancelled, uiImage == nil, url == self.url {
                if let loaded = await CoverImageLoader.shared.image(for: url),
                   url == self.url {
                    uiImage = loaded
                    break
                }
                attempt += 1
                guard attempt <= 2, !Task.isCancelled, url == self.url else { break }
                try? await Task.sleep(nanoseconds: UInt64((attempt == 1 ? 0.5 : 1.5) * 1_000_000_000))
            }
        }
    }
}
