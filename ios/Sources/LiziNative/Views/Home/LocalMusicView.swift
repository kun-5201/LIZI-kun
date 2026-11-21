import SwiftUI
import UniformTypeIdentifiers

/// 本地音乐区（r22j 模板 v2：~/workspace/lizi-home-template-portrait.png /
/// lizi-home-template-landscape.png——首页最末、首屏之外，下滑才看到；
/// 首屏一个像素都不许露本地音乐，见 HomeView 文件头）。
///
/// - 标题「本地音乐」28pt 粗体；下面是文件夹卡片（60 高、paper2 底、
///   圆角 14：蓝色 folder.fill 图标 + 「本地音乐」+ 首数/空态 + chevron，
///   点卡片原地展开/收起文件列表）。
/// - 文件行：音符图标 + 标题 + 歌手 + 时长 mm:ss；点行即播
///   （`Track(platform: "local", ...)`，`PlaybackStore.resolveURL` 对
///   platform == "local" 直接走 `LocalMusic.fileURL(id:)`，不走平台/LX，
///   见 PlaybackStore.swift:681）。正在播的行给播放指示（波形图标）。
/// - 每行尾部一个删除按钮（点即删，`LocalMusic.delete`；原档还在文件
///   App 里，可重新导入）。没有用左滑删除：VStack 行里没有 List 的
///   swipeActions，自己写横滑手势会和页面竖滑抢触摸（同环上滑的教训，
///   见 HomeCoverRingView），删除按钮不抢手势。
/// - 「导入本地音乐」黑 pill 按钮（44 高）：sheet 弹系统文件选择器
///   （UIDocumentPicker，UTType.audio，多选，asCopy——照抄壳版
///   `LocalFilesBridge.swift` 的选择器参数），选完后台
///   `LocalMusic.importFiles` 拷进沙盒 `Documents/LocalMusic/` +
///   写 index.json 清单，再刷新列表 + 状态行（导入 N 首、失败 M 个）。
/// - r31-download：下面再加一张「下载管理」卡（同款 60 高）：进
///   DownloadsView（正在下载进度 / 已下载点播 / 左滑删除）。Lizi 没有
///   独立的「我的」页，首页就是我的 hub，这张卡就是我的页面那行的落点；
///   下载不混进本地音乐清单（见 DownloadStore 文件头），这张卡只放入口。
/// - r33-download-entry：上面那张卡已搬走——现在在 HomeView 面板之下
///   VStack、本地音乐区块正上方、`if localMusicShown` 之外（开关关了
///   它也一直在、首屏一眼见）；本文件里不再有下载管理入口，不留两个。
/// - 空态用壳版原文（`LocalMusicPlaceholderView` 旧文案，原样搬过来）：
///   「还没有导入本地音频。在文件 App 里选音频文件，导入后出现在这里。」
///   不编假文件，文件夹里没歌就是空态。
/// - `onAppear` 与导入/删除后刷新列表（`LocalMusic.list()` 按导入时间倒序）。
/// - r28：订阅 `DownloadStore.downloadCompletedNotification`，下载一完成
///   就 `refresh()`——只在完成那一刻刷一次，不轮询、不跟进度走；
///   订阅随视图走（`.onReceive`），视图消失即取消，不留泄漏。
struct LocalMusicSectionView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @State private var entries: [LocalMusic.Entry] = []
    @State private var isExpanded = false
    @State private var isPickerPresented = false
    @State private var statusLine: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地音乐")
                .font(.liziBody(size: 28, weight: .bold))
                .foregroundColor(LiziTokens.ink)

            // 文件夹卡片：点开是文件列表，再点文件播放（模板 v2）。
            Button(action: { isExpanded.toggle() }) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地音乐")
                            .font(.liziBody(size: 16, weight: .semibold))
                            .foregroundColor(LiziTokens.ink)
                        Text(entries.isEmpty ? "空文件夹" : "\(entries.count) 首")
                            .font(.liziBody(size: 12))
                            .foregroundColor(LiziTokens.ink2)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(LiziTokens.ink2)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 60)
                .background(LiziTokens.paper2)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起本地音乐文件夹" : "展开本地音乐文件夹")

            if isExpanded {
                if entries.isEmpty {
                    Text("还没有导入本地音频。在文件 App 里选音频文件，导入后出现在这里。")
                        .font(.liziBody(size: 13))
                        .foregroundColor(LiziTokens.ink2)
                        .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(entries, id: \.id) { entry in
                            LocalMusicRowView(
                                entry: entry,
                                isPlaying: playback.currentTrack?.id == entry.id && playback.isPlaying,
                                onPlay: { playback.play(trackFor(entry)) },
                                onDelete: {
                                    _ = LocalMusic.delete(id: entry.id)
                                    statusLine = "已删除《\(entry.title)》"
                                    refresh()
                                }
                            )
                            if entry.id != entries.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background(LiziTokens.paper2)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }

            // 导入按钮：黑 pill，44 高（模板 v2）。
            Button(action: { isPickerPresented = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                    Text("导入本地音乐")
                        .font(.liziBody(size: 15, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            .accessibilityLabel("导入本地音乐")

            if let statusLine {
                Text(statusLine)
                    .font(.liziBody(size: 12))
                    .foregroundColor(LiziTokens.ink2)
            }
        }
        .padding(.horizontal, 16)
        .onAppear { refresh() }
        // r28：下载完成即刷新（通知在落盘 + 写清单之后发，list() 里已有新歌；
        // 文件夹计数与展开后的文件列表同一次 refresh() 一起更新）。
        .onReceive(NotificationCenter.default.publisher(for: DownloadStore.downloadCompletedNotification)) { _ in
            refresh()
        }
        .sheet(isPresented: $isPickerPresented) {
            LocalMusicDocumentPicker(
                onPick: { urls in
                    isPickerPresented = false
                    importPicked(urls)
                },
                onCancel: { isPickerPresented = false }
            )
        }
    }

    private func trackFor(_ entry: LocalMusic.Entry) -> Track {
        // r22l 编译修：Track.init 的成员顺序是 id 在前、platform 在后
        //（Models.swift init(id:platform:title:...)），
        // 之前 platform 写在 id 前面，报「argument 'id' must precede 'platform'」。
        Track(
            id: entry.id,
            platform: "local",
            title: entry.title,
            artist: entry.artists.joined(separator: " / "),
            durationMs: Int(entry.duration * 1000)
        )
    }

    private func refresh() { entries = LocalMusic.list() }

    private func importPicked(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task.detached {
            let result = LocalMusic.importFiles(urls: urls)
            await MainActor.run {
                refresh()
                statusLine = result.failed == 0
                    ? "已导入 \(result.imported.count) 首"
                    : "已导入 \(result.imported.count) 首，失败 \(result.failed) 个"
            }
        }
    }
}

/// 本地音乐文件行：音符图标 + 标题 + 歌手 + 时长；点行播放；尾部删除按钮。
private struct LocalMusicRowView: View {
    let entry: LocalMusic.Entry
    let isPlaying: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPlaying ? "waveform" : "music.note")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(isPlaying ? .blue : LiziTokens.ink2)
                .frame(width: 20)
            Button(action: onPlay) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.liziBody(size: 15, weight: .medium))
                            .foregroundColor(isPlaying ? .blue : LiziTokens.ink)
                            .lineLimit(1)
                        Text(entry.artists.isEmpty ? "未知歌手" : entry.artists.joined(separator: " / "))
                            .font(.liziBody(size: 12))
                            .foregroundColor(LiziTokens.ink2)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(Self.durationText(entry.duration))
                        .font(.liziBody(size: 12))
                        .foregroundColor(LiziTokens.ink2)
                }
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("删除《\(entry.title)》")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// 系统文件选择器（照抄壳版 LocalFilesBridge.swift 的参数：
/// UTType.audio，多选，asCopy；不申请任何隐私权限，选择器本身就是
/// 用户手势授权）。选完/取消都要把 sheet 的绑定清掉，否则 sheet 关不掉。
private struct LocalMusicDocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.audio],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
