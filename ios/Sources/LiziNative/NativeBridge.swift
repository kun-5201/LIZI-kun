import Foundation

/// 原生版直调共享 Swift 服务的薄类型化封装入口（P0 骨架，P1 填充）。
///
/// 方向：SwiftUI → NativeBridge → 各平台 Service（NetEaseService / SidecarService /
/// LXSourceRegistry / Lrclib 等，见 NATIVE-REWRITE-PLAN.md §2）。
/// 不走 HTTP、不走 LocalHttpServer、不走 WebView：服务类的 `handle(HttpRequest)`
/// 是 HTTP 入口，原生直调要调它们内部 typed 方法（现在多为 private，P1 逐个开
/// 口子时再加类型化封装，不在此处改共享文件）。
///
/// P0 的方法全部是空实现（返回空结果），只把签名占住，让 P1 工人按签名填。
/// 绝不编假数据：没接通的平台就返回空，不伪造曲目/歌词/链接。
enum NativeBridge {
    /// 按平台搜歌（只用各平台自己的搜索接口，绝不用 LX 搜索）。
    static func search(keyword: String, source: String) async -> SearchResult {
        // TODO(P1): 调对应平台 Service 的搜索方法。
        _ = keyword
        _ = source
        return SearchResult()
    }

    /// 取一首歌的可播直链（P1：平台官方 → 已登录个人云盘 → LX → 演示音的编排器）。
    static func songURL(for track: Track, quality: String) async -> URL? {
        // TODO(P1): 取链编排器；LX 返回的 URL 进 AVPlayer 前要重新定白名单策略。
        _ = track
        _ = quality
        return nil
    }

    /// 取一首歌的歌词行（P1：官方 → LRCLIB → 无词显示歌名，绝不用 ♪ 作假）。
    static func lyrics(for track: Track) async -> [LyricLine] {
        // TODO(P1): 各平台 lyric() + Lrclib 兜底 + LRC/YRC 行切分。
        _ = track
        return []
    }
}
