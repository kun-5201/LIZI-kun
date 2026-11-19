import SwiftUI
import UIKit

/// 原生封面取图：进程内代理 → 直链 → 默认占位（三级兜底，P3-D）。
///
/// 链路（照抄岛/锁屏已有的做法，见 `NativeIslandCoordinator.coverData` 与
/// `NowPlayingCoordinator`：进程内合成 `HttpRequest` 直调
/// `Proxies.proxyImage`，**不走 HTTP 回环、不复活 LocalHttpServer**；
/// `Proxies.swift` 本身一行没改，只在这里包一层薄封装）：
/// 1. 代理：`/api/img`（白名单 + 各家 Referer 绕防盗链，含 r15 的
///    `.mzstatic.com`；代理 403/502 时记诊断，不拦直链）。
/// 2. 直链：`URLSession` 直接拉原地址（个别不上白名单的图床、代理挂了时
///    的兜底；防盗链严格的图床这一步会空，由调用方占位）。
/// 3. 占位：两步都失败返回 `nil`，调用方显示默认图（白色底 + 音符，
///    绝不用 ♪ 冒充封面本身）。
///
/// 内存缓存：同一 URL 在一次启动里只拉一次（`NSCache`，约 50MB 上限，
/// 封面图本身不大；跨启动不持久化，磁盘缓存不在本轮范围）。
actor CoverImageLoader {
    static let shared = CoverImageLoader()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.totalCostLimit = 50 * 1024 * 1024
        cache.countLimit = 200
    }

    /// 取一张封面的 `UIImage`；三级都失败返回 `nil`（调用方显示占位）。
    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        // 1) 进程内代理（Proxies.proxyImage：白名单 + Referer + https 升级）。
        let proxyReq = HttpRequest(method: "GET", path: "/api/img",
                                   query: ["url": url.absoluteString],
                                   headers: [:], body: Data())
        let proxyResp = await Proxies.proxyImage(proxyReq)
        if (200...299).contains(proxyResp.status),
           let image = UIImage(data: proxyResp.body) {
            store(image, for: url)
            return image
        }
        // 2) 直链兜底。
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                store(image, for: url)
                return image
            }
        } catch {
            // 直链也失败：返回 nil，调用方占位，不抛错、不编图。
        }
        return nil
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
            if let loaded = await CoverImageLoader.shared.image(for: url),
               url == self.url {
                uiImage = loaded
            }
        }
    }
}
