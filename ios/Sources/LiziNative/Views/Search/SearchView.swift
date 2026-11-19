import SwiftUI

/// 搜索与搜索结果页（NATIVE-REWRITE-PLAN.md §1 屏幕 2，P1）。
///
/// 组成：顶栏搜索框（平时收起只留图标，聚焦展开并自动获焦）+ 音源切换条
/// （「全部」+ 7 家平台）+ 曲目列表 + 搜索历史下拉。
/// 本页不建导航、不改 RootView：点行是播放（走 PlaybackStore），
/// 歌手/专辑/歌单行点按跳 P2 内容页（P2-A 已接线：extraSections 里
/// nav.show(.artist/.album/.playlist)，导航由 AppNavigation / RootView 负责。
struct SearchView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @EnvironmentObject private var nav: AppNavigation
    @StateObject private var viewModel = SearchViewModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FocusState private var searchFocused: Bool

    /// 搜索框是否展开（收起时只留 38pt 圆钮图标）。
    /// r20：初始 true——进搜索页就是展开态，TextField 首帧已在视图树里才能聚焦。
    /// 之前初始 false 时进页只有 38pt 图标，TextField 根本不存在，焦点无处可落，
    /// 用户必须再点一次图标才出键盘。失焦且输入为空时仍由下面的
    /// onChange(searchFocused) 收回成圆钮，不影响进页即打字的验收。
    @State private var searchExpanded = true
    /// 「清空记录」两步确认的第一步是否已按下（3 秒内第二下才真清，照抄壳版）。
    @State private var clearArmed = false

    private var isCompact: Bool { sizeClass == .compact }

    /// 历史下拉的出现条件：聚焦且输入为空且有历史（照抄壳版）。
    private var showHistory: Bool {
        searchFocused
            && viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.history.isEmpty
    }

    /// 当前音源的 hint 文案：「XX · 输入关键词」。
    private var sourceHint: String {
        let name = viewModel.source == "all"
            ? "全部音源"
            : SearchViewModel.label(for: viewModel.source)
        return "\(name) · 输入关键词"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 16)
                .padding(.top, 8)
            sourceStrip
                .padding(.top, 10)
            ZStack(alignment: .top) {
                resultsContent
                if showHistory {
                    // 面板外的透明层：点外面收起键盘（从而收起面板）。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { searchFocused = false }
                    historyPanel
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
            }
        }
        .background(SearchDesignTokens.paper)
        .onChange(of: searchFocused) { _ in
            // 失焦且输入为空 → 收回 38pt 圆钮；有内容时保持展开（壳版同款）。
            if !searchFocused, viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.easeInOut(duration: 0.25)) { searchExpanded = false }
            }
        }
        .onChange(of: searchExpanded) { _ in
            if searchExpanded { searchFocused = true }
        }
        .onAppear {
            // r20 进页即聚焦：searchExpanded 初始 true，TextField 首帧已挂上，
            // 这里同步置焦点——刻意不用 DispatchQueue.main.async / Task /
            // asyncAfter：异步回调会脱离点按手势的同步链路，键盘弹不出
            // （第 14 轮 btn-search-now 同类问题）。导航本身是 RootView 的
            // 同步 state 切换（无 NavigationStack / sheet / 转场动画），
            // onAppear 就落在点按触发的那次更新里，焦点不会丢。
            // 失焦后点图标再展开仍走上面的 onChange(searchExpanded) 聚焦。
            searchFocused = true
        }
    }

    // MARK: - 顶栏搜索框

    /// 平时 38pt 圆钮只留图标；聚焦展开并自动获焦（壳版 .search 的折叠形态）。
    @ViewBuilder
    private var searchBar: some View {
        HStack {
            if searchExpanded || !viewModel.query.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(SearchDesignTokens.ink2)
                    TextField("搜索歌曲", text: $viewModel.query)
                        .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                        .foregroundStyle(SearchDesignTokens.ink)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            viewModel.searchNow()
                            searchFocused = false
                        }
                        .onChange(of: viewModel.query) { _ in viewModel.queryChanged() }
                    if !viewModel.query.isEmpty {
                        Button {
                            viewModel.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(SearchDesignTokens.ink3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(SearchDesignTokens.paper2)
                .clipShape(RoundedRectangle(cornerRadius: 19))
                .overlay(
                    RoundedRectangle(cornerRadius: 19)
                        .stroke(SearchDesignTokens.rule, lineWidth: 1)
                )
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { searchExpanded = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(SearchDesignTokens.ink2)
                        .frame(width: 38, height: 38)
                        .background(Color.clear)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.25), value: searchExpanded)
    }

    // MARK: - 音源切换条

    /// 横向可滚动：「全部」+ 7 家；当前源墨色边框 + 加粗；末尾 hint 固定在右侧。
    private var sourceStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchViewModel.allSources, id: \.self) { id in
                        sourceChip(id: id)
                    }
                }
            }
            Text(sourceHint)
                .font(SearchDesignTokens.font(SearchDesignTokens.size12))
                .foregroundStyle(SearchDesignTokens.ink3)
                .lineLimit(1)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
    }

    private func sourceChip(id: String) -> some View {
        let selected = viewModel.source == id
        return Button {
            viewModel.selectSource(id)
        } label: {
            Text(SearchViewModel.label(for: id))
                .font(SearchDesignTokens.font(
                    SearchDesignTokens.size13,
                    weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? SearchDesignTokens.ink : SearchDesignTokens.ink3)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(SearchDesignTokens.paper2)
                .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius10))
                .overlay(
                    RoundedRectangle(cornerRadius: SearchDesignTokens.radius10)
                        .stroke(selected ? SearchDesignTokens.ink : SearchDesignTokens.rule,
                                lineWidth: selected ? 1.5 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索历史下拉

    /// 聚焦且为空时弹出：每条可删，顶部「清空记录」两步确认（照抄壳版）。
    private var historyPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("搜索记录")
                    .font(SearchDesignTokens.font(SearchDesignTokens.size12))
                    .foregroundStyle(SearchDesignTokens.ink3)
                Spacer()
                Button {
                    if clearArmed {
                        clearArmed = false
                        viewModel.clearHistory()
                    } else {
                        clearArmed = true
                        Task {
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                            clearArmed = false
                        }
                    }
                } label: {
                    Text(clearArmed ? "确认清空？" : "清空记录")
                        .font(SearchDesignTokens.font(SearchDesignTokens.size12))
                        .foregroundStyle(clearArmed ? SearchDesignTokens.accent : SearchDesignTokens.ink3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ForEach(viewModel.history, id: \.self) { item in
                HStack(spacing: 8) {
                    Button {
                        // 只设文字：onChange 的 300ms 防抖会接手搜，不在这里
                        // 再调 searchNow，否则同一条词会连搜两次。
                        viewModel.query = item
                        searchFocused = false
                    } label: {
                        Text(item)
                            .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                            .foregroundStyle(SearchDesignTokens.ink)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    Button {
                        viewModel.deleteHistory(item)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SearchDesignTokens.ink3)
                            .frame(width: 22, height: 22)
                            .background(SearchDesignTokens.coverPlaceholder)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(maxHeight: 320)
        .background(SearchDesignTokens.paper2)
        .clipShape(RoundedRectangle(cornerRadius: SearchDesignTokens.radius14))
        .overlay(
            RoundedRectangle(cornerRadius: SearchDesignTokens.radius14)
                .stroke(SearchDesignTokens.rule, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 16, x: 0, y: 8)
    }

    // MARK: - 结果列表

    @ViewBuilder
    private var resultsContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isSearching, isResultEmpty {
                    ProgressView()
                        .padding(.top, 40)
                } else if viewModel.source == "all" {
                    allModeGroups
                } else {
                    singleModeList
                }
                if !viewModel.isSearching, isResultEmpty {
                    emptyState
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// 是否没有任何结果内容（曲目/分组/歌单/歌手/专辑全空）。
    private var isResultEmpty: Bool {
        viewModel.tracks.isEmpty
            && viewModel.groups.allSatisfy { $0.tracks.isEmpty }
            && viewModel.playlists.isEmpty
            && viewModel.artists.isEmpty
            && viewModel.albums.isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 25))
                .foregroundStyle(SearchDesignTokens.ink3)
            Text(emptyStateText)
                .font(SearchDesignTokens.font(SearchDesignTokens.size14))
                .foregroundStyle(SearchDesignTokens.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// 空态文案：单音源接口挂了时明说失败原因（不是「搜不到」）；否则按搜过/没搜区分。
    private var emptyStateText: String {
        if viewModel.source != "all", let error = viewModel.searchError {
            return error
        }
        return viewModel.hasSearched ? "没有找到相关结果" : "输入关键词搜索歌曲"
    }

    /// 单音源模式：平铺列表，滑到底加载更多（hasMore 时）。
    @ViewBuilder
    private var singleModeList: some View {
        if let error = viewModel.searchError, !viewModel.tracks.isEmpty {
            searchErrorRow(error)
        }
        ForEach(viewModel.tracks) { track in
            trackRow(track, in: viewModel.tracks)
                .onAppear {
                    if track.id == viewModel.tracks.last?.id
                        && track.platform == viewModel.tracks.last?.platform {
                        viewModel.loadMore()
                    }
                }
        }
        if viewModel.isLoadingMore {
            ProgressView()
                .padding(.vertical, 16)
        }
        if !viewModel.tracks.isEmpty, !viewModel.hasMore, !viewModel.isSearching {
            Text("已显示全部 \(viewModel.totalCount > 0 ? viewModel.totalCount : viewModel.tracks.count) 条")
                .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                .foregroundStyle(SearchDesignTokens.ink3)
                .padding(.vertical, 16)
        }
        extraSections
    }

    /// 「全部」模式：按平台分组、组标题行分隔；各组独立「加载更多」。
    /// 有 error 的空组也展示（只一行失败提示），否则接口挂了的平台会无声消失。
    @ViewBuilder
    private var allModeGroups: some View {
        ForEach(viewModel.groups.filter { !$0.tracks.isEmpty || $0.error != nil }) { group in
            SearchGroupHeaderView(
                title: SearchViewModel.label(for: group.platform),
                count: group.totalCount > 0 ? group.totalCount : group.tracks.count)
            if let error = group.error {
                searchErrorRow(error)
            }
            ForEach(group.tracks) { track in
                trackRow(track, in: group.tracks)
            }
            if group.hasMore {
                Button {
                    viewModel.loadMore(platform: group.platform)
                } label: {
                    Text("加载更多")
                        .font(SearchDesignTokens.font(SearchDesignTokens.size13))
                        .foregroundStyle(SearchDesignTokens.ink2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        if viewModel.isLoadingMore {
            ProgressView()
                .padding(.vertical, 16)
        }
    }

    /// 歌单/歌手/专辑：点按跳 P2 内容页（P2-A 接线，只加导航，不改搜索逻辑）。
    /// 歌单行传 isRank：酷我榜单行（playlist.isRank，rank 标记来自榜单/搜索字典
    /// 的 rank 字段）详情走 /api/kuwo/rank/tracks；其余歌单走普通详情接口。
    @ViewBuilder
    private var extraSections: some View {
        if !viewModel.artists.isEmpty {
            SearchGroupHeaderView(title: "歌手", count: viewModel.artists.count)
            ForEach(viewModel.artists) { artist in
                Button {
                    nav.show(.artist(platform: artist.source, id: artist.id))
                } label: {
                    SearchPlainRowView(title: artist.name, subtitle: "")
                }
                .buttonStyle(.plain)
            }
        }
        if !viewModel.albums.isEmpty {
            SearchGroupHeaderView(title: "专辑", count: viewModel.albums.count)
            ForEach(viewModel.albums) { album in
                Button {
                    nav.show(.album(platform: album.source, id: album.id))
                } label: {
                    SearchPlainRowView(title: album.title, subtitle: album.artist)
                }
                .buttonStyle(.plain)
            }
        }
        if !viewModel.playlists.isEmpty {
            SearchGroupHeaderView(title: "歌单", count: viewModel.playlists.count)
            ForEach(viewModel.playlists) { playlist in
                Button {
                    nav.show(.playlist(platform: playlist.source, id: playlist.id,
                                       isRank: playlist.isRank))
                } label: {
                    SearchPlainRowView(title: playlist.title, subtitle: playlist.creator)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 上游失败提示行（接口挂了，不是「搜不到」）：红字小行，不拦着其他组展示。
    private func searchErrorRow(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12))
            Text(error)
                .font(SearchDesignTokens.font(SearchDesignTokens.size13))
        }
        .foregroundStyle(.red.opacity(0.85))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityLabel("搜索失败：\(error)")
    }

    // MARK: - 点行播放

    /// 点行播放：同队列同位置（当前在播的同一首）点则 toggle 播放/暂停；
    /// 否则把整列设为队列并从该位置开始播。
    private func trackRow(_ track: Track, in list: [Track]) -> some View {
        let isCurrent = playback.currentTrack?.id == track.id
            && playback.currentTrack?.platform == track.platform
            && playback.currentIndex >= 0
            && playback.queue.indices.contains(playback.currentIndex)
            && playback.queue[playback.currentIndex].track.id == track.id
            && playback.queue[playback.currentIndex].track.platform == track.platform
        return TrackRowView(track: track, isCurrent: isCurrent, isCompact: isCompact) {
            if isCurrent {
                playback.togglePlay()
            } else if let index = list.firstIndex(where: {
                $0.id == track.id && $0.platform == track.platform
            }) {
                playback.setQueue(list, startAt: index)
            }
        }
    }
}

#Preview {
    SearchView()
        .environmentObject(PlaybackStore())
        .environmentObject(AppNavigation())
}
