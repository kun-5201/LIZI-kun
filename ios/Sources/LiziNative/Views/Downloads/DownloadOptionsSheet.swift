import SwiftUI

/// 下载选音质 sheet（r31，Moumusic DownloadOptionsSheet 的结构、Lizi 原生实现，
/// 不抄 Moumusic 代码，Moumusic 是 GPL-3.0）。
///
/// - 单首或批量：tracks.count == 1 显示歌名 + 歌手，多首显示「共 N 首歌曲」。
/// - 默认档 = 全局默认音质（DownloadStore.defaultDownloadQuality，
///   即 SettingsStore.storedAudioQuality()）。
/// - 打开时真探该首歌实际可用的档（DownloadStore.availableQualities：
///   逐档真探取链），只列探到的档；默认档不在可用档里时自动降到
///   可用档里最高的一档（available 按 rank 降序，第一档即最高）。
/// - 文案写明「不支持的音质会自动降级，并显示实际下载音质」；
///   下载完成记的是取链实际回的档位（DownloadStore.finishDownload），
///   不是请求的档位。
/// - 点「开始下载 / 开始批量下载」调 DownloadStore.downloadBatch，
///   调完即关 sheet，不等下完；已下载的单首歌按钮禁用（不重复下）。
struct DownloadOptionsSheet: View {
    let tracks: [Track]

    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedQuality: AudioQuality
    @State private var available: [AudioQuality] = []
    @State private var isLoading = true

    init(tracks: [Track]) {
        self.tracks = tracks
        _selectedQuality = State(initialValue: DownloadStore.defaultDownloadQuality)
    }

    /// 单首且已下载时不再给下载按钮（不重复下）。
    private var singleAlreadyDownloaded: Bool {
        tracks.count == 1 && DownloadStore.shared.record(for: tracks[0]) != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section("下载内容") {
                    Text(tracks.count == 1 ? tracks[0].title : "共 \(tracks.count) 首歌曲")
                        .lineLimit(2)
                    if tracks.count == 1 {
                        Text(tracks[0].artist)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if singleAlreadyDownloaded {
                        Text("这首歌已下载，去「下载管理」查看")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("下载音质") {
                    ForEach(available.isEmpty ? [.standard] : available, id: \.self) { quality in
                        Button {
                            selectedQuality = quality
                        } label: {
                            HStack {
                                Text(quality.sourceDisplayName)
                                Spacer()
                                if selectedQuality == quality {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(PlayerTokens.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .frame(minHeight: 44)
                    }
                    Text(isLoading
                         ? "正在读取当前音源支持的音质…"
                         : "不支持的音质会自动降级，并显示实际下载音质")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        DownloadStore.shared.downloadBatch(tracks, quality: selectedQuality, store: playback)
                        dismiss()
                    } label: {
                        Label(tracks.count > 1 ? "开始批量下载" : "开始下载",
                              systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(singleAlreadyDownloaded)
                }
            }
            .navigationTitle("下载设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .task {
            guard let first = tracks.first else {
                isLoading = false
                return
            }
            available = await DownloadStore.shared.availableQualities(for: first, store: playback)
            if !available.contains(selectedQuality), let first = available.first {
                selectedQuality = first
            }
            isLoading = false
        }
        .presentationDetents([.medium, .large])
    }
}
