import Foundation
import CryptoKit

/// 本地磁盘缓存（r48-11/12）：已加载过的封面、歌词、音频信息落盘，
/// 二次显示直接读本地，不再联网重复拉取；只缓存已经加载过的，不预缓存。
///
/// 三路共用一个存储池、一个上限（设置页可调，见 SettingsStore）：
/// - 封面 `covers/`：图片原始字节，按封面 URL 的 SHA256 存；
///   读：CoverImageLoader（首页/播放器/搜索）+ NowPlayingCoordinator
///   锁屏静态图；写：联网取图成功后。
/// - 歌词 `lyrics/`：官方歌词原文 JSON（Folia 字段形 mainText /
///   wordByWordText / translationText / romanizationText /
///   isPureMusic / source），按 `lyric-<平台>-<id>.json` 存；
///   读：NativeBridge.lyrics(for:)；
///   写：官方回了内容才写（官方空时不写；自动匹配结果进缓存；
///   空结果也不写否定缓存）。
/// - 音频信息 `audio/`：取链结果 JSON（url + 音质/码率/试听标记 +
///   取回时间），按 `audio-<平台>-<id>-<档位>.json` 存；读：
///   NativeBridge.songURL；写：取到可用地址才写。流地址本身是
///   短命的（网易 expi 约 20 分钟），TTL 只给 10 分钟，到期即废；
///   播一半死了由 PlaybackStore.handlePlaybackFailure 调
///   removeAudio(for:) 清掉，免得下次重试又拿到同一条死链。
///   LX 腿不进缓存（脚本自带取链、过期规则未知）；云盘/本地/下载
///   腿本来就是本地文件，也不进。
///
/// 上限与清理（数值写死在这里，设置页只调上限、不改规则）：
/// - 上限键 `lizi.coverDiskCacheLimitMB`，默认 **16384 MB（16GB）**，
///   用户可调，最小 512MB、最大 16GB；存在 UserDefaults，重启保留。
/// - 封面/歌词 TTL 30 天，音频信息 TTL 10 分钟；过期文件读到即删、当 miss。
/// - 写缓存后若总量超上限：先清过期文件，再按最后访问时间从旧到新清，
///   直到总量 ≤ 上限的 80%（留 20% 余量，免得每次写都触发清理）。
/// - 调小上限后多出的缓存由下次 prune 清掉（设置页写上限后立即调一次
///   pruneIfNeeded）；调大上限不丢已有缓存。
/// - 失效更新：封面换 URL 即换键（新 URL 自然 miss、重新拉）；同 URL
///   内容变了靠 30 天 TTL 兜底（CDN 封面 URL 按内容寻址，同 URL 换图
///   极少）；歌词同理；音频信息靠 10 分钟 TTL。
/// - 位置：Library/Caches（系统空间紧张时可清，可重拉的数据放这里是对的；
///   不要放 Documents——会进备份、占用户备份空间）。
/// - 并发：NSLock 串行化全部文件操作（CoverImageLoader actor、主线程、
///   detached 取图任务都可能同时读写）。
enum DiskCache {
    /// 磁盘缓存上限（MB）：默认 16GB；最小 512MB、最大 16GB。
    static let defaultLimitMB = 16384
    static let minLimitMB = 512
    static let maxLimitMB = 16384
    static let limitKey = "lizi.coverDiskCacheLimitMB"

    /// 封面 / 歌词 TTL：30 天。音频信息 TTL：10 分钟（流地址短命）。
    static let coverTTL: TimeInterval = 30 * 24 * 3600
    static let lyricTTL: TimeInterval = 30 * 24 * 3600
    static let audioTTL: TimeInterval = 600

    /// 清理后目标水位：上限的 80%。
    static let pruneTargetRatio = 0.8

    enum Kind: String {
        case cover, lyric, audio
        var dirName: String {
            switch self {
            case .cover: return "covers"
            case .lyric: return "lyrics"
            case .audio: return "audio"
            }
        }
        var ttl: TimeInterval {
            switch self {
            case .cover: return coverTTL
            case .lyric: return lyricTTL
            case .audio: return audioTTL
            }
        }
    }

    private static let lock = NSLock()

    /// 当前上限（字节）：读 UserDefaults，非法/缺失回默认 16GB，夹到 [512MB, 16GB]。
    // r48-12：上限读写唯一口径（设置页与 DiskCache 同读这里，不各写各的）。
    static func limitBytes() -> Int64 {
        let raw = UserDefaults.standard.object(forKey: limitKey) as? Int
        let mb = raw ?? defaultLimitMB
        let clamped = min(max(mb, minLimitMB), maxLimitMB)
        return Int64(clamped) * 1024 * 1024
    }

    static func rootDir() -> URL {
        // r55：.first! 改回落（见 LocalFiles.directory 同款）。
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("lizi/disk-cache", isDirectory: true)
    }

    static func dir(for kind: Kind) -> URL {
        rootDir().appendingPathComponent(kind.dirName, isDirectory: true)
    }

    /// 封面键：URL 字符串的 SHA256（URL 里有各种不合法文件名字符，不直接当文件名）。
    static func coverKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 歌词键：文件名可读（播一半死了要按前缀清时用不上，歌词失败不单独清）。
    static func lyricKey(platform: String, id: String) -> String {
        "lyric-\(sanitized(platform))-\(sanitized(id))"
    }

    /// 音频信息键：文件名可读（播死了按 `audio-<平台>-<id>-` 前缀整组清）。
    static func audioKey(platform: String, id: String, quality: String) -> String {
        "audio-\(sanitized(platform))-\(sanitized(id))-\(sanitized(quality))"
    }

    static func audioPrefix(platform: String, id: String) -> String {
        "audio-\(sanitized(platform))-\(sanitized(id))-"
    }

    private static func sanitized(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return s.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private static func fileURL(kind: Kind, key: String) -> URL {
        dir(for: kind).appendingPathComponent(key)
    }

    /// 读：命中且未过期返回数据；缺失/过期返回 nil（过期文件当场删掉）。
    // r48-11：三路共用读口径（封面/歌词/音频信息都先读盘、miss 再联网）。
    /// touch=true 时刷新最后访问时间（封面/歌词的 LRU 用）；音频信息
    /// 不刷新（r48-11：流地址 TTL 是硬过期，读一次不能续 10 分钟）。
    static func data(kind: Kind, key: String, touch: Bool = true) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(kind: kind, key: key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        if Date().timeIntervalSince(mtime) > kind.ttl {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 刷新 mtime = 最后访问时间（LRU 按它排）。
        if touch {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return data
    }

    /// 写：原子写盘（写一半不留坏文件），写完按需清理。
    // r48-11：只缓存已经加载过的（调用方联网成功后才调这里，不预缓存）。
    static func store(_ data: Data, kind: Kind, key: String) {
        lock.lock(); defer { lock.unlock() }
        let dirURL = dir(for: kind)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let url = fileURL(kind: kind, key: key)
        try? data.write(to: url, options: [.atomic])
        pruneLocked()
    }

    static func remove(kind: Kind, key: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(kind: kind, key: key))
    }

    /// 清掉某首歌的全部音频信息缓存（播一半死了调：免得下次重试又拿到同一条死链）。
    static func removeAudio(platform: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = audioPrefix(platform: platform, id: id)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir(for: .audio),
                                                                       includingPropertiesForKeys: nil) else { return }
        for f in files where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// r48-13：清空全部本地缓存（封面 + 歌词 + 音频信息三路），返回释放的字节数。
    /// 只删本缓存根目录（Library/Caches/lizi/disk-cache）下的文件——已下载的
    /// 本地音乐在 Documents/LocalMusic、登录态在钥匙串、其他设置在
    /// UserDefaults，都不在这个目录里，一律不动。清完下次显示再重新联网
    /// 取、重新写缓存；正在播的歌不受影响（播放器手里已有流地址，内存
    /// 封面缓存也不动）。
    static func clearAll() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let freed = totalBytesLocked()
        try? FileManager.default.removeItem(at: rootDir())
        return freed
    }

    /// 当前总量（字节）：三路子目录之和。
    static func totalBytes() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalBytesLocked()
    }

    private static func totalBytesLocked() -> Int64 {
        var total: Int64 = 0
        for kind in [Kind.cover, Kind.lyric, Kind.audio] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir(for: kind), includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for f in files {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    /// 清理：过期文件全清；仍超上限时按 mtime 从旧到新清，直到 ≤ 上限 80%。
    // r48-12：调小上限后由设置页立即调一次；每次写缓存后也调一次（超了才动作）。
    /// 调小上限后由设置页立即调一次；每次写缓存后也调一次（超了才动作）。
    static func pruneIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
    }

    private static func pruneLocked() {
        let limit = limitBytes()
        let target = Int64(Double(limit) * pruneTargetRatio)
        let now = Date()
        // 1) 过期文件全清。
        for kind in [Kind.cover, Kind.lyric, Kind.audio] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir(for: kind), includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files {
                if let mtime = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   now.timeIntervalSince(mtime) > kind.ttl {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
        // 2) 仍超目标水位时按最后访问时间从旧到新清。
        var total = totalBytesLocked()
        guard total > target else { return }
        var all: [(url: URL, mtime: Date, size: Int)] = []
        for kind in [Kind.cover, Kind.lyric, Kind.audio] {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir(for: kind),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for f in files {
                if let vals = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                   let mtime = vals.contentModificationDate {
                    all.append((f, mtime, vals.fileSize ?? 0))
                }
            }
        }
        all.sort { $0.mtime < $1.mtime }
        for entry in all where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= Int64(entry.size)
        }
    }
}
