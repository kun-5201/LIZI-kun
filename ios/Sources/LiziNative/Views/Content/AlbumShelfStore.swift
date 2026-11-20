import Foundation

/// 本地收藏专辑仓库（P2 我的专辑 3D 陈列架 + 专辑页收藏按钮共用）。
///
/// - 只做本地收藏：`UserDefaults` 存 `[Album]`（Codable），键 `lizi.native.collectedAlbums`。
/// - 本阶段未登录（登录迁移是 P4 的事），不接服务端歌单、不做同步、不编假数据。
/// - 匹配键是 `(id, source)`：同一张专辑在不同平台算两条收藏；`source` 即平台标识
///   （netease / qq / qishui / bodian / kuwo / applemusic），与 Models.swift 一致。
/// - 读失败（无数据 / 解码失败）返回空数组；写失败静默忽略，只影响下次启动。
/// - 无强制解包：全程 `try?` / `guard let`，解码失败不崩。
enum AlbumShelfStore {
    static let key = "lizi.native.collectedAlbums"

    /// 读出全部本地收藏（按收藏顺序；没有收藏时返回 `[]`，不编假专辑）。
    static func load() -> [Album] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        guard let albums = try? JSONDecoder().decode([Album].self, from: data) else { return [] }
        return albums
    }

    /// 是否已收藏（按 `id` + 平台 `source` 匹配）。
    static func contains(albumId: String, platform: String) -> Bool {
        load().contains { $0.id == albumId && $0.source == platform }
    }

    /// 收藏 / 取消收藏切换：已收藏则移除（同一 `(id, source)` 全清，防重复残留），
    /// 未收藏则追加到末尾。保存失败静默忽略。
    static func toggle(_ album: Album) {
        var albums = load()
        if albums.contains(where: { $0.id == album.id && $0.source == album.source }) {
            albums.removeAll { $0.id == album.id && $0.source == album.source }
        } else {
            albums.append(album)
        }
        save(albums)
    }

    private static func save(_ albums: [Album]) {
        guard let data = try? JSONEncoder().encode(albums) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
