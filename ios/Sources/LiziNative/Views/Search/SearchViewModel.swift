import Foundation

/// 搜索页状态机（P1-C）。
///
/// - 搜索只调各平台自有搜索接口（`NativeBridge.search`），绝不走 LX。
/// - 「全部」时 7 家平台并发搜（TaskGroup），一家回空/挂了不拖垮其他家；
///   每家独立分页（`hasMore` 时各组单独加载更多）。
/// - 输入防抖 300ms；序号 `searchSeq` 丢弃晚到的旧响应。
/// - 搜索历史只存关键词：UserDefaults `lizi.search.history`，去重、最新在前、上限 20。
/// - 当前音源：UserDefaults `lizi.searchSource`（与壳版同键），切源后用当前词重搜。
///
/// 诚实边界（P1 集成已补）：`NativeBridge.search` 上游失败时在 `SearchResult.errors`
/// 里按平台回原因，`PlatformGroup.error` / 单音源 `searchError` 透传到 UI；
/// 空组 + 有 error = 接口挂了，空组 + 没 error = 该平台搜不到。
@MainActor
final class SearchViewModel: ObservableObject {

    // MARK: - 平台

    /// 7 家平台（与 Models / NativeBridge 的 platform id 一致）。
    static let platformIds = ["netease", "qq", "kugou", "qishui", "bodian", "kuwo", "applemusic"]
    /// 音源切换条的全部选项（「全部」+ 7 家）。
    static let allSources = ["all"] + platformIds

    /// 平台 id → 显示名（照抄壳版 QR_LABEL）。
    static func label(for platform: String) -> String {
        switch platform {
        case "all": return "全部"
        case "netease": return "网易云音乐"
        case "qq": return "QQ 音乐"
        case "kugou": return "酷狗"
        case "qishui": return "汽水"
        case "bodian": return "波点"
        case "kuwo": return "酷我音乐"
        case "applemusic": return "Apple Music"
        default: return platform
        }
    }

    // MARK: - 常量

    static let historyKey = "lizi.search.history"
    static let sourceKey = "lizi.searchSource"
    static let historyMax = 20
    static let pageLimit = 20

    // MARK: - 发布状态

    /// 搜索框文字。
    @Published var query = ""
    /// 当前音源（"all" 或平台 id）。
    @Published var source = "all"
    /// 单音源模式的曲目。
    @Published var tracks: [Track] = []
    /// 单音源模式的歌单/歌手/专辑（桥接层目前只填 tracks，留空态占位；P2 之前不编）。
    @Published var playlists: [Playlist] = []
    @Published var artists: [Artist] = []
    @Published var albums: [Album] = []
    /// 单音源模式是否还有更多。
    @Published var hasMore = false
    /// 单音源模式的上游总条数。
    @Published var totalCount = 0
    /// 「全部」模式的分组结果（每家一组；空组也在里面，视图只展示非空组）。
    @Published var groups: [PlatformGroup] = []
    /// 正在搜第一页。
    @Published var isSearching = false
    /// 正在加载更多。
    @Published var isLoadingMore = false
    /// 是否已经搜过一次（区分「还没搜」和「搜了没结果」两种空态）。
    @Published var hasSearched = false
    /// 单音源模式的上游失败信息（nil = 没失败；与「搜不到结果」区分开）。
    @Published var searchError: String?
    /// 搜索历史（最新在前）。
    @Published var history: [String] = []

    /// 「全部」模式下一家平台的结果。
    struct PlatformGroup: Identifiable {
        var platform: String
        var tracks: [Track]
        var hasMore: Bool
        var totalCount: Int
        /// 该平台的上游失败信息（nil = 没失败；空组 + 有 error = 接口挂了，
        /// 空组 + 没 error = 该平台搜不到）。
        var error: String?
        var id: String { platform }
    }

    // MARK: - 内部

    private var searchSeq = 0
    private var debounceTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.sourceKey) ?? "all"
        source = Self.allSources.contains(saved) ? saved : "all"
        history = Self.readHistory()
    }

    // MARK: - 输入与防抖

    /// 搜索框文字变化时调用：空了就清结果；否则 300ms 防抖后搜。
    func queryChanged() {
        debounceTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchSeq += 1 // 作废在途的旧响应
            isSearching = false
            isLoadingMore = false
            clearResults()
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.runSearch(query: q)
        }
    }

    /// 键盘「搜索」键 / 历史点选后立即搜（不等防抖）。
    func searchNow() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // r55：活动日志（死亡快照回落用；只记平台+query）。
        DiagLog.shared.recordActivity("search \(source) \(String(q.prefix(80)))")
        debounceTask?.cancel()
        Task { await runSearch(query: q) }
    }

    // MARK: - 切音源

    /// 切音源：持久化，有当前词就用新音源重搜一遍（壳版同款行为）。
    func selectSource(_ id: String) {
        guard id != source, Self.allSources.contains(id) else { return }
        source = id
        UserDefaults.standard.set(id, forKey: Self.sourceKey)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        debounceTask?.cancel()
        Task { await runSearch(query: q) }
    }

    // MARK: - 搜索执行

    /// 搜第一页（同时把关键词记进历史）。
    func runSearch(query: String) async {
        searchSeq += 1
        let seq = searchSeq
        saveHistory(query)
        hasSearched = true
        isSearching = true
        isLoadingMore = false
        clearResults(keepHasSearched: true)

        if source == "all" {
            // 7 家并发：TaskGroup 里一家回空/挂了只影响自己那组，不拖垮其他家。
            let results = await withTaskGroup(of: (String, SearchResult).self) { group in
                for platform in Self.platformIds {
                    group.addTask {
                        (platform, await NativeBridge.search(
                            platform: platform, query: query,
                            limit: Self.pageLimit, offset: 0))
                    }
                }
                var out: [(String, SearchResult)] = []
                for await item in group { out.append(item) }
                return out
            }
            guard seq == searchSeq else { return }
            let order = Self.platformIds
            groups = results
                .sorted { (order.firstIndex(of: $0.0) ?? 99) < (order.firstIndex(of: $1.0) ?? 99) }
                .map { PlatformGroup(platform: $0.0, tracks: dedupedById($0.1.tracks),
                                    hasMore: $0.1.hasMore, totalCount: $0.1.totalCount,
                                    error: $0.1.errors[$0.0]) }
        } else {
            let result = await NativeBridge.search(platform: source, query: query,
                                                   limit: Self.pageLimit, offset: 0)
            guard seq == searchSeq else { return }
            // r55：按 id 去重——上游可回重歌，ForEach 同 id 会 trap。
            tracks = dedupedById(result.tracks)
            playlists = dedupedById(result.playlists)
            artists = dedupedById(result.artists)
            albums = dedupedById(result.albums)
            hasMore = result.hasMore
            totalCount = result.totalCount
            searchError = result.errors[source]
        }
        isSearching = false
    }

    /// 单音源模式：滑到底加载更多。
    func loadMore() {
        guard source != "all", hasMore, !isSearching, !isLoadingMore else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchSeq += 1
        let seq = searchSeq
        isLoadingMore = true
        Task {
            let result = await NativeBridge.search(platform: source, query: q,
                                                   limit: Self.pageLimit, offset: tracks.count)
            guard seq == searchSeq else { return }
            // r55：分页 append 也可跨页重——合并后再按 id 去重。
            tracks = dedupedById(tracks + result.tracks)
            hasMore = result.hasMore
            totalCount = result.totalCount
            searchError = result.errors[source]
            isLoadingMore = false
        }
    }

    /// 「全部」模式：某一家组内加载更多（各组独立分页）。
    func loadMore(platform: String) {
        guard source == "all",
              let index = groups.firstIndex(where: { $0.platform == platform }),
              groups[index].hasMore, !isSearching, !isLoadingMore else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searchSeq += 1
        let seq = searchSeq
        isLoadingMore = true
        Task {
            let result = await NativeBridge.search(platform: platform, query: q,
                                                   limit: Self.pageLimit,
                                                   offset: groups[index].tracks.count)
            guard seq == searchSeq else { return }
            // r55：组内分页 append 也可跨页重——合并后再按 id 去重。
            groups[index].tracks = dedupedById(groups[index].tracks + result.tracks)
            groups[index].hasMore = result.hasMore
            groups[index].totalCount = result.totalCount
            groups[index].error = result.errors[platform]
            isLoadingMore = false
        }
    }

    // MARK: - 历史

    static func readHistory() -> [String] {
        let arr = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        return Array(arr
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(historyMax))
    }

    /// 记一条历史：去重、最新在前、上限 20。只存关键词，不存敏感信息。
    func saveHistory(_ q: String) {
        let needle = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        var list = history.filter { $0 != needle }
        list.insert(needle, at: 0)
        list = Array(list.prefix(Self.historyMax))
        history = list
        UserDefaults.standard.set(list, forKey: Self.historyKey)
    }

    func deleteHistory(_ q: String) {
        history.removeAll { $0 == q }
        UserDefaults.standard.set(history, forKey: Self.historyKey)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    private func clearResults(keepHasSearched: Bool = false) {
        tracks = []
        playlists = []
        artists = []
        albums = []
        groups = []
        hasMore = false
        totalCount = 0
        searchError = nil
        if !keepHasSearched { hasSearched = false }
    }
}
