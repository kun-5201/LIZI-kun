import Foundation

/// LRC / YRC 歌词解析（P1 新写；逻辑照抄壳版 public/player.js 的 parseLyrics / parseYrcLine / parseLrcLines，
/// 时间统一转毫秒；不抄 Web 代码，只复用解析规则）。
///
/// r55 Folia 歌词：入口改 parseFolia(mainText:wordByWordText:
/// translationText:romanizationText:isPureMusic:)——服务端已按 Folia
/// 字段形回包（{mainText, wordByWordText, translationText,
/// romanizationText, isPureMusic, source}），客户端只做解析与对齐：
/// - wordByWordText（逐字 YRC）优先；没有就退回 mainText（先按 YRC 试，
///   再按 LRC；尖括号 YRC 可能装在 mainText 里）。
/// - 翻译/音译都是行级 LRC 文本，按行起点（毫秒取整到 10ms 的键）对齐
///   到主行（translation / romanization）。
/// - 无词时返回空（`format == "none"`，lines 为空）；调用方显示歌名，绝不用 ♪ 作假歌词。
/// - 纯音乐（isPureMusic）直接回空行 + isPureMusic true，不解析、不编词。
enum LyricsParser {

    /// 统一入口：Folia 字段形 → ParsedLyrics。
    static func parseFolia(mainText: String, wordByWordText: String,
                           translationText: String = "", romanizationText: String = "",
                           isPureMusic: Bool = false) -> ParsedLyrics {
        if isPureMusic { return ParsedLyrics(lines: [], format: "none", isPureMusic: true) }
        let trMap = translationMap(translationText)
        let roMap = translationMap(romanizationText)
        func attach(_ lines: [LyricLine]) -> [LyricLine] {
            var out = lines
            for i in out.indices {
                let key = translationKey(ms: out[i].startMs)
                out[i].translation = trMap[key] ?? ""
                out[i].romanization = roMap[key] ?? ""
            }
            out.sort { $0.startMs < $1.startMs }
            return out
        }
        if !wordByWordText.isEmpty {
            let lines = parseYRC(wordByWordText)
            if !lines.isEmpty { return ParsedLyrics(lines: attach(lines), format: "yrc") }
        }
        if !mainText.isEmpty {
            // 尖括号 YRC 可能装在 mainText 里；先按 YRC 试一次，再退回 LRC。
            // 普通 LRC 文本没有 `[起点,时长]` 行首也没有尖括号戳，
            // parseYRC 会返回空，不会误判。
            let yrcLines = parseYRC(mainText)
            if !yrcLines.isEmpty { return ParsedLyrics(lines: attach(yrcLines), format: "yrc") }
            let lines = parseLRC(mainText, translationMap: trMap)
            if !lines.isEmpty {
                var out = lines
                for i in out.indices {
                    out[i].romanization = roMap[translationKey(ms: out[i].startMs)] ?? ""
                }
                return ParsedLyrics(lines: out, format: "lrc")
            }
        }
        return ParsedLyrics(lines: [], format: "none")
    }

    // MARK: - YRC（逐字）

    /// 解析 YRC 全文 → 行数组（时间毫秒）。QQ 式 `[起点,时长]` 与尖括号式
    /// `<mm:ss.xxx>字` 两种都认（r22a：新接口返回尖括号式，见文件底注释）。
    static func parseYRC(_ yrc: String) -> [LyricLine] {
        yrc.components(separatedBy: "\n").compactMap { parseYRCLine($0) ?? parseAngleYRCLine($0) }
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

    /// 解析尖括号 YRC 一行 → LyricLine（r22a 新增；新接口格式）。
    /// 行格式：`<00:00.000>青<00:00.366>花<00:00.732>爱…`，或前面再带一个
    /// LRC 式行首 `[00:00.00]<00:00.000>青…`（混合式）。第一个尖括号时间戳
    /// 是行起点，之后每段 `<时间>字` 是一个逐字；字结束 = 下一字起点
    /// （末字 +1 秒）。行首的方括号时间戳不参与（它只是行起点，尖括号第一个
    /// 时间戳与它同值）；字文本里若夹着方括号戳也一并剥掉。
    static func parseAngleYRCLine(_ line: String) -> LyricLine? {
        let pattern = #"<(\d+):(\d+(?:\.\d+)?)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        struct Stamp { let startMs: Int; let text: String }
        var stamps: [Stamp] = []
        for (i, m) in matches.enumerated() {
            guard m.numberOfRanges == 3 else { continue }
            let mm = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let startMs = Int((Double(mm) * 60 + ss) * 1000)
            let textStart = m.range.location + m.range.length
            let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            guard textEnd > textStart else { continue }
            let raw = ns.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            let text = raw.replacingOccurrences(of: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            stamps.append(Stamp(startMs: startMs, text: text))
        }
        guard !stamps.isEmpty else { return nil }
        let words = stamps.enumerated().map { (i, s) in
            LyricWord(text: s.text, startMs: s.startMs,
                      endMs: (i + 1 < stamps.count) ? stamps[i + 1].startMs : s.startMs + 1000)
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LyricLine(startMs: words[0].startMs, text: text, words: words)
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
            var text = stampRegex.stringByReplacingMatches(
                in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            // 防御：尖括号时间戳（YRC 变体）若残留在这里，一并剥掉，
            // 行文本永不含原始时间戳（r22a 横屏实测：红字里出现 <00:00.000> 原文）。
            text = text.replacingOccurrences(of: #"<\d+:\d+(?:\.\d+)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

// MARK: - r22a 根因（横屏歌词显示未解析的 YRC 原文，像素实测钉死）
//
// 实测（用户横屏截图 1206×555 px = 874×402 pt，在播 青花瓷 / 周杰伦）：
// 歌词区红字是 `<00:00.000>青<00:00.366>花<00:00.732>爱…`、
// `<00:05.490>词<00:06.588>： <00:07.686>方…`、`<00:10.980>曲<00:12.078>： <0…`，
// 逐字时间戳原样显示。竖屏歌词没这个问题。
// - 横竖屏不是两条渲染路径：竖屏与横屏都经 PlayerView.lyricsZone → 同一个
//   LyricsZoneView（LyricsPanelView.swift），当前行有 words 时逐字上色
//   （wordByWordText），否则原样 Text(line.text)。代码里不存在第二条横屏
//   渲染路径；「横屏走了另一条路径」是误判。
// - 真正的差异是曲目歌词格式不同：竖屏《发如雪》是普通 LRC，可解析；
//   横屏《青花瓷》是新接口返回的尖括号 YRC 变体
//   `<mm:ss.xxx>字`（与 QQ 式 `[起点ms,行时长ms](起点,时长,0)字` 不同）。
//   旧 parseYRCLine 只认 QQ 式行首，尖括号行返回 nil → parseYRC 返回 []
//   → 回落 parseLRC；parseLRC 只剥 `[...]` 时间戳，`<...>` 完整留在
//   line.text 里（混合式 `[行首]<00:00.000>青…` 剥掉方括号后正好剩下尖括号
//   原文，words = []），渲染走 Text(line.text) 原样显示。
// - 修法（本文件，r22a）：
//   (1) 新增 parseAngleYRCLine：认 `<mm:ss.xxx>字`，首个戳为行起点，
//       每段一个逐字（字结束 = 下一字起点，末字 +1 秒），兼容行首带
//       `[mm:ss.xx]` 的混合式；parseYRC 每行先试 QQ 式再试尖括号式。
//   (2) parseFolia(mainText:wordByWordText:) 里 mainText 字段也先按 YRC
//       试一次（尖括号 YRC 可能装在 mainText 字段里），再退回 LRC。
//   (3) parseLRC 防御性剥掉残留的 `<...>` 时间戳：行文本永不含原始时间戳。
// - 7 平台歌词格式（NativeBridge.lyrics(for:)；取词是各平台自己的 lyric
//   接口，解析是同一条 LyricsParser.parseFolia，与平台无关）：
//   网易 /api/lyric、QQ /api/qq/lyric、酷狗 /api/kugou/lyric、汽水
//   /api/qishui/lyric、波点 /api/bodian/lyric 回 Folia 字段形
//   （mainText + wordByWordText + translationText + romanizationText）。
//   任一平台官方与解析都空时，统一走跨平台自动匹配（NativeBridge，
//   网易 → QQ → 酷狗 → 汽水，10 秒总预算，搜不到就跳过，不编数据）；
//   再空则返回空（format "none"，调用方显示歌名，绝不用 ♪ 作假歌词）。
//   酷我 / Apple Music 无歌词接口（Folia 也无此源），r55 已删，
//   不编假数据，等用户定。
