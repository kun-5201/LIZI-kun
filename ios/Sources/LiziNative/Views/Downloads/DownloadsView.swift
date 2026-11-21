import SwiftUI

/// 下载管理页（r31，Moumusic DownloadsView 的结构、Lizi 原生实现，
/// 不抄 Moumusic 代码，Moumusic 是 GPL-3.0）。
///
/// - 「正在下载」区：封面 + 歌名 + 请求音质 + 进度条 + 百分比
///   （还没拿到总大小时进度条转圈、不显示百分比）。
/// - 「已下载」区：封面 + 歌名 + 歌手 · 实际音质（记录里的实际下载音质，
///   不是请求的档位）；点一行直接播（本地文件优先，见 PlaybackStore
///   resolveURL 的本地优先分支），播完关本页；左滑删除（删文件 + 删记录）。
/// - 空态照抄原文案：「暂无下载」「在歌曲列表或播放页的“更多操作”中选择下载」。
/// - 入口：设置「存储与下载」分区、播放页底部下载键（已下载态点按）。
///   首页不放入口（用户 2026-11-21 10:25 取消）。
/// - 注意：这里只列下载清单（DownloadStore.records）；r27 旧下载仍在
///   本地音乐清单里，不进本页（见 DownloadStore 文件头 legacy 段）。
struct DownloadsView: View {
    @EnvironmentObject private var playback: PlaybackStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloads = DownloadStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty && downloads.activeDownloads.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("暂无下载")
                            .font(.headline)
                        Text("在歌曲列表或播放页的“更多操作”中选择下载")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List {
                        if !downloads.activeDownloads.isEmpty {
                            Section("正在下载") {
                                ForEach(activeSorted) { item in
                                    HStack(spacing: 12) {
                                        CoverImageView(url: item.track.coverURL)
                                            .frame(width: 52, height: 52)
                                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.track.title).lineLimit(1)
                                            Text("请求音质：\(item.requestedQuality.displayName)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let fraction = item.fraction {
                                                ProgressView(value: fraction)
                                            } else {
                                                ProgressView()
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if let fraction = item.fraction {
                                            Text("\(Int(fraction * 100))%")
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(minHeight: 44)
                                }
                            }
                        }

                        if !downloads.records.isEmpty {
                            Section("已下载") {
                                ForEach(downloads.records) { record in
                                    Button {
                                        playback.play(record.track)
                                        dismiss()
                                    } label: {
                                        HStack(spacing: 12) {
                                            CoverImageView(url: record.track.coverURL)
                                                .frame(width: 52, height: 52)
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(record.track.title)
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text("\(record.track.artist) · \(record.displayQuality)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Spacer()
                                            Image(systemName: "play.circle")
                                                .foregroundStyle(PlayerTokens.accent)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                                .onDelete { offsets in
                                    for index in offsets { downloads.delete(downloads.records[index]) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("下载管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 正在下载按 id 排定（字典本身无序，列表不跳动）。
    private var activeSorted: [DownloadStore.ActiveDownload] {
        downloads.activeDownloads.values.sorted { $0.id < $1.id }
    }
}
