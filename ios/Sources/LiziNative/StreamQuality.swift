import AVFoundation
import CoreMedia
import Foundation

/// 实测链（r31 音质系统替换）：servedQuality 的判定链。
///
/// 流程结构学 Moumusic PlayerService 的 measuredQuality /
/// RemoteAudioInspector（流实测 → 文件头 → URL 文件名 → 音源标签），
/// 按 Lizi 结构原生实现，不抄 Moumusic 代码（GPL-3.0）。
/// 判定顺序（先有实证的赢，后面的只在前面给不出时才跑）：
/// 1. AVFoundation 流实测：读实际要播的 AVAssetTrack（编码格式 /
///    采样率 / 位深 / 声道数 / 实测码率）→ 档位。
/// 2. 文件头实测：Range 取流的前 4KB，FLAC STREAMINFO（采样率/位深）
///    或 MP3 首帧码率 → 档位；WAV → 无损。
/// 3. URL 文件名：QQ 直链前缀（地面真相）或无损容器后缀（.flac → 无损）。
/// 4. 音源返回标签：canon 翻译出的档位；翻译不出的原文原样回（rawLabel）。
/// 5. 全给不出 → (nil, nil)，UI 显示「未知」。
///
/// 注意（R6 的边界）：第 1/2 步里的码率是「实测流本身的属性」
/// （测到的就是测到的，实测直接定档）；R6 删的是「拿音源宣称的 br
/// 去压档位名」（canon 的 br 分段、verified 的 br 压档），两者不是
/// 一回事——实测不压宣称，实测直接定档。
/// 调用点：PlaybackStore 起播后（startItem 成功）异步跑一趟，
/// 测到就替换 resolve 时的宣称档位，测不到就保留宣称档位；
/// 实测是后台任务，绝不阻塞起播。
enum StreamQualityMeasurer {

    /// 一次判定的结果：tier 有值 = 定档了（显示 tier 名）；
    /// tier 为空但 rawLabel 有值 = 音源给了档位名但翻译不出
    /// （如 "192k"），显示原文；两个都空 = 未知。
    typealias Measured = (tier: AudioQuality?, rawLabel: String?)

    /// 跑完整条判定链（见文件头顺序）。
    static func measure(url: URL, claimed: AudioQuality?,
                        servedLabel: String?) async -> Measured {
        // 1）AVFoundation 流实测。
        if let track = await loadAudioTrack(from: AVURLAsset(url: url), timeout: 6),
           let facts = await streamFacts(of: track),
           let tier = measuredQuality(claimed: claimed, facts: facts) {
            return (tier, nil)
        }
        // 2）文件头实测（AVFoundation 读不出流式 FLAC 时的兜底）。
        if let tier = await headerTier(of: url) { return (tier, nil) }
        // 3）URL 文件名。
        if let tier = tierFromURL(url) { return (tier, nil) }
        // 4）音源返回标签：翻译出的档位，或翻译不出的原文。
        if let claimed { return (claimed, nil) }
        if let label = servedLabel, !label.isEmpty { return (nil, label) }
        // 5）全给不出：未知。
        return (nil, nil)
    }

    // MARK: - 第 1 步：AVFoundation 流实测

    /// 读音频轨道（6 秒上限：流式 FLAC 常读不出来，超时就放行，
    /// 不把起播拖死；Moumusic 同款 TaskGroup + 超时任务）。
    private static func loadAudioTrack(from asset: AVURLAsset,
                                       timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask { try? await asset.loadTracks(withMediaType: .audio).first }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 解码器实际要拿到的东西：编码格式、采样率、位深、声道数、实测码率。
    private struct StreamFacts {
        let format: AudioFormatID
        let sampleRate: Double
        let channels: Int
        let bits: Int
        let bitrate: Double
    }

    private static func streamFacts(of track: AVAssetTrack) async -> StreamFacts? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              basic.mSampleRate > 0 else { return nil }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0
        return StreamFacts(format: basic.mFormatID, sampleRate: basic.mSampleRate,
                           channels: Int(basic.mChannelsPerFrame), bits: Int(basic.mBitsPerChannel),
                           bitrate: Double(rate))
    }

    /// 流实测定档（Moumusic measuredQuality 的结构，原生重写）：
    /// 宣称的高档位只在实测撑得住时才认（母带要 176.4kHz 以上、
    /// 环绕声要多声道、杜比要 E-AC-3/AC-3 编码）；撑不住就按实测
    /// 通用规则落档——杜比编码 → 杜比；6 声道以上 → 沉浸环绕声；
    /// 无损 → Hi-Res（采样率 ≥88.2k / 位深 ≥24 / 码率 ≥1.8M 任一）
    /// 或无损；其余按实测码率分 320k / 128k 两档。
    /// 实测存在时恒有结果（不回 nil），第 1 步就是终审。
    private static func measuredQuality(claimed: AudioQuality?,
                                        facts: StreamFacts) -> AudioQuality? {
        let lossless = facts.format == kAudioFormatFLAC || facts.format == kAudioFormatAppleLossless
        let dolby = facts.format == kAudioFormatEnhancedAC3 || facts.format == kAudioFormatAC3
        let hiRes = lossless && (facts.sampleRate >= 88_200 || facts.bits >= 24 || facts.bitrate >= 1_800_000)
        switch claimed {
        case .master:
            if lossless, facts.sampleRate >= 176_400 { return .master }
        case .atmos:
            // 高清环绕声需要多声道：一轨 Hi-Res 立体声只是 Hi-Res，
            // 不是环绕声。
            if facts.channels >= 3 { return .atmos }
        case .dolby:
            if dolby { return .dolby }
        case .surround:
            if facts.channels >= 6 { return .surround }
        default:
            break
        }
        if dolby { return .dolby }
        if facts.channels >= 6 { return .surround }
        if lossless { return hiRes ? .hires : .lossless }
        return facts.bitrate >= 224_000 ? .exhigh : .standard
    }

    // MARK: - 第 2 步：文件头实测

    /// Range 取流的前 4KB 看文件头（只读头，不拉整条流；
    /// 本地 file:// 与非 http(s) 地址不跑这步，AVFoundation 已够）。
    /// FLAC 读 STREAMINFO 的采样率/位深；MP3 读首帧码率；
    /// WAV 认 RIFF/WAVE；其它（OggS 等）给不出就回 nil，往下走。
    private static func headerTier(of url: URL) async -> AudioQuality? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              data.count >= 4 else { return nil }
        // FLAC："fLaC" + 4 字节块头 + STREAMINFO（34 字节）。
        // STREAMINFO 内偏移 10..17 是采样率（20 位）/ 声道（3 位）/
        // 位深（5 位）/ 总采样数（36 位）：采样率 = b18<<12 | b19<<4 | b20>>4，
        // 位深 = ((b20&1)<<4 | b21>>4) + 1。
        if data.count >= 26, data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43,
           data[4] & 0x7F == 0 {
            let sampleRate = (Int(data[18]) << 12) | (Int(data[19]) << 4) | (Int(data[20]) >> 4)
            let bits = (((Int(data[20]) & 0x01) << 4) | (Int(data[21]) >> 4)) + 1
            if sampleRate >= 88_200 || bits >= 24 { return .hires }
            if sampleRate > 0 { return .lossless }
        }
        // WAV：RIFF....WAVE。
        if data.count >= 12, data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
           data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45 {
            return .lossless
        }
        // MP3：跳过 ID3v2（有就按同步安全长度跳），找 MPEG1 Layer III 帧头。
        var offset = 0
        if data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            let size = ((Int(data[6]) & 0x7F) << 21) | ((Int(data[7]) & 0x7F) << 14)
                | ((Int(data[8]) & 0x7F) << 7) | (Int(data[9]) & 0x7F)
            offset = 10 + size
        }
        // MPEG1 Layer III 码率表（kbps，索引 1..14）。
        let mpeg1Layer3Bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        let scanEnd = min(data.count - 4, 1024)
        var i = offset
        while i <= scanEnd {
            let b0 = data[i], b1 = data[i + 1], b2 = data[i + 2]
            if b0 == 0xFF, b1 & 0xE0 == 0xE0, (b1 >> 3) & 0x03 == 0x03, (b2 >> 1) & 0x03 == 0x01 {
                let bitrateKbps = mpeg1Layer3Bitrates[Int((b2 >> 4) & 0x0F)]
                if bitrateKbps >= 320 { return .exhigh }
                if bitrateKbps >= 192 { return .higher }
                if bitrateKbps > 0 { return .standard }
                return nil
            }
            i += 1
        }
        return nil
    }

    // MARK: - 第 3 步：URL 文件名

    /// QQ 直链前缀是地面真相；无损容器后缀（.flac/.ape/.wav/.alac）
    /// 定无损；有损后缀定不了具体档（128k 与 320k 都是 .mp3），回 nil
    /// 往下走，不猜。
    private static func tierFromURL(_ url: URL) -> AudioQuality? {
        let name = url.lastPathComponent
        if name.count >= 5, let q = AudioQuality.qqFilenameTier(String(name.prefix(4))) { return q }
        switch url.pathExtension.lowercased() {
        case "flac", "ape", "wav", "alac": return .lossless
        default: return nil
        }
    }
}
