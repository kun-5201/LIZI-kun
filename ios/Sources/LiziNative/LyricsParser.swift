import Foundation

/// LRC / YRC 歌词解析（P1 新写；逻辑照抄壳版 public/player.js 的 parseLyrics / parseYrcLine / parseLrcLines，
/// 时间统一转毫秒；不抄 Web 代码，只复用解析规则）。
///
/// 规则：
/// - YRC 优先（逐字）：行首 `[起点ms,行时长ms]`，字 `(字起点ms,字时长ms,0)字`。
/// - 没有 YRC 时退回 LRC：`[mm:ss.xx]文本`，一行可带多个时间戳。
/// - 无词时返回空（`format == "none"`，lines 为空）；调用方显示歌名，绝不用 ♪ 作假歌词。
enum LyricsParser {

    /// 统一入口：YRC 优先，没有就退回 LRC（照抄 player.js parseLyrics）。
    static func parse(lyric: String, yrc: String, tlyric: String = "", ytlrc: String = "") -> ParsedLyrics {
        let trMap = translationMap(tlyric.isEmpty ? ytlrc : tlyric)
        if !yrc.isEmpty {
            var lines = parseYRC(yrc)
            if !lines.isEmpty {
                for i in lines.indices {
                    lines[i].translation = trMap[translationKey(ms: lines[i].startMs)] ?? ""
                }
                lines.sort { $0.startMs < $1.startMs }
                return ParsedLyrics(lines: lines, format: "yrc")
            }
        }
        if !lyric.isEmpty {
            let lines = parseLRC(lyric, translationMap: trMap)
            if !lines.isEmpty { return ParsedLyrics(lines: lines, format: "lrc") }
        }
        return ParsedLyrics(lines: [], format: "none")
    }

    /// 只传 LRC 字符串的兼容入口（照抄 player.js parseLRC）。
    static func parseLRCOnly(_ lrc: String, tlyric: String = "") -> [LyricLine] {
        parseLRC(lrc, translationMap: translationMap(tlyric))
    }

    // MARK: - YRC（逐字）

    /// 解析 YRC 全文 → 行数组（时间毫秒）。
    static func parseYRC(_ yrc: String) -> [LyricLine] {
        yrc.components(separatedBy: "\n").compactMap { parseYRCLine($0) }
    }

    /// 解析 YRC 一行 → LyricLine（照抄 player.js parseYrcLine；时间毫秒）。
    /// 行格式：`[12000,3000](12000,500,0)今(12500,500,0)天…`
    static func parseYRCLine(_ line: String) -> LyricLine? {
        guard let head = line.range(of: #"^\[(\d+),(\d+)\]"#, options: .regularExpression) else { return nil }
        let headText = String(line[head])
        let nums = headText.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
        guard nums.count >= 2 else { return nil }
        let lineStartMs = nums[0]
        let rest = String(line[head.upperBound...])
        var words: [LyricWord] = []
        // 字：(起点毫秒,时长毫秒,0)字
        let pattern = #"\((\d+),(\d+),\d+\)([^()]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = rest as NSString
        for m in regex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges == 4 else { continue }
            let text = ns.substring(with: m.range(at: 3))
            guard !text.isEmpty,
                  let start = Int(ns.substring(with: m.range(at: 1))),
                  let dur = Int(ns.substring(with: m.range(at: 2))) else { continue }
            words.append(LyricWord(text: text, startMs: start, endMs: start + dur))
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LyricLine(startMs: lineStartMs, text: text, words: words)
    }

    // MARK: - LRC（行）

    /// 解析 LRC 全文 → 行数组（照抄 player.js parseLrcLines；一行可带多个时间戳）。
    static func parseLRC(_ lrc: String, translationMap trMap: [String: String] = [:]) -> [LyricLine] {
        var out: [LyricLine] = []
        let stampPattern = #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#
        guard let stampRegex = try? NSRegularExpression(pattern: stampPattern) else { return [] }
        for raw in lrc.components(separatedBy: "\n") {
            let ns = raw as NSString
            let matches = stampRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let text = stampRegex.stringByReplacingMatches(
                in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for m in matches {
                guard m.numberOfRanges == 3 else { continue }
                let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                let startMs = Int((Double(mm) * 60 + ss) * 1000)
                let key = translationKey(ms: startMs)
                out.append(LyricLine(startMs: startMs, text: text, translation: trMap[key] ?? ""))
            }
        }
        out.sort { $0.startMs < $1.startMs }
        return out
    }

    /// 翻译映射表：时间戳 → 译文（照抄 player.js buildTrMap；键与 parseLRC / parseYRC 共用）。
    static func translationMap(_ tlyric: String) -> [String: String] {
        var map: [String: String] = [:]
        guard !tlyric.isEmpty else { return map }
        let pattern = #"^\[(\d+):(\d+(?:[.:]\d+)?)\](.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return map }
        for raw in tlyric.components(separatedBy: "\n") {
            let ns = raw as NSString
            guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges == 4 else { continue }
            let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
            let startMs = Int((Double(mm) * 60 + ss) * 1000)
            map[translationKey(ms: startMs)] = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return map
    }

    /// 翻译表键：与 player.js 的 `${mm}:${ss}` 同义（毫秒取整到 10ms，避免浮点抖动）。
    private static func translationKey(ms: Int) -> String {
        "\(ms / 10)"
    }

    // MARK: - 当前行判定

    /// 当前行下标（atMs 时刻正在唱的行；没有行或还没开始返回 -1）。
    static func currentLineIndex(lines: [LyricLine], atMs: Int) -> Int {
        var idx = -1
        for (i, line) in lines.enumerated() {
            if line.startMs <= atMs { idx = i } else { break }
        }
        return idx
    }

    /// 当前行（没有时返回 nil）。
    static func currentLine(lines: [LyricLine], atMs: Int) -> LyricLine? {
        let idx = currentLineIndex(lines: lines, atMs: atMs)
        guard idx >= 0 else { return nil }
        return lines[idx]
    }

    /// 上一行（没有时返回 nil）。
    static func previousLine(lines: [LyricLine], atMs: Int) -> LyricLine? {
        let idx = currentLineIndex(lines: lines, atMs: atMs)
        guard idx > 0 else { return nil }
        return lines[idx - 1]
    }

    /// 下一行（没有时返回 nil）。
    static func nextLine(lines: [LyricLine], atMs: Int) -> LyricLine? {
        let idx = currentLineIndex(lines: lines, atMs: atMs)
        guard idx + 1 < lines.count else { return nil }
        return lines[idx + 1]
    }

    /// 当前字下标（逐字行内；没有逐字数据时返回 -1）。
    static func currentWordIndex(line: LyricLine, atMs: Int) -> Int {
        guard !line.words.isEmpty else { return -1 }
        var idx = -1
        for (i, w) in line.words.enumerated() {
            if w.startMs <= atMs { idx = i } else { break }
        }
        return idx
    }
}
