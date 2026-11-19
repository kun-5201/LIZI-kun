import ActivityKit
import Foundation

/// Shared Live Activity attributes for Lizi 歌词灵动岛.
/// This file is compiled into BOTH the app target and the widget extension
/// target, so it must stay identical in both. Keep it dependency-free apart
/// from ActivityKit/Foundation.
struct LiziLyricsAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The lyric line currently being sung.
        var currentLyric: String
        /// Previous line, if any.
        var prevLyric: String?
        /// Next line, if any.
        var nextLyric: String?
        /// Playback progress 0...1 (0 when duration unknown).
        var progress: Double
        /// Whether the player is currently playing (vs paused).
        var isPlaying: Bool
        /// Total duration in seconds (0 when unknown); drives the
        /// elapsed / remaining readout in the expanded island.
        var duration: Double = 0
        /// Whether the current track is liked (star in the expanded island).
        var isLiked: Bool = false
        /// Album cover, downsampled to ~120px JPEG by the app before pushing
        /// (nil = no cover yet / track has none; the widget draws a ♪ instead).
        var coverData: Data? = nil
    }

    var title: String
    var artist: String
}
