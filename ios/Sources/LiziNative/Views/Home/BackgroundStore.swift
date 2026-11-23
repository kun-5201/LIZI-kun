import SwiftUI
import UIKit

/// 首页 / 大厅背景（r31-imagebg，用户 2026-11-21 07:15：静态图片背景 +
/// 动态壁纸，两件一起做；对照表 #18 大厅背景、#20 主页自定义背景）。
///
/// 三种模式（`Mode`，UserDefaults 键 `lizi.background.mode`，重启保留）：
/// - `.none`（默认）：不设图片/视频，首页就是原来的纸色底
///   （`LiziTokens.paper`，HomeBackgroundView 底层一直垫着它）。
/// - `.image`（静态图片）：设置页外观区「背景」→「选图片」，系统
///   PhotosPicker 选图（`matching: .images`），读到 Data 后按最长边
///   1920px 等比缩小、JPEG 0.85 写进沙盒
///   `Application Support/lizi.background/background-image.jpg`，
///   只存文件、不存相册引用——相册原图删了、重启后背景都在。
/// - `.video`（动态壁纸）：设置页外观区「背景」→「选动态壁纸」，
///   系统 PhotosPicker 选视频（`matching: .videos`），
///   `loadFileRepresentation` 拿到的临时文件原样拷进沙盒
///   `Application Support/lizi.background/background-video.<原扩展名>`
///   （mov/mp4/m4v，不转码），文件名记 UserDefaults
///   `lizi.background.videoFile`；首页用 AVPlayer 静音循环播
///   （见 `LoopingVideoBackgroundView`，BackgroundView.swift）。
///
/// 图片和视频文件都保留着，模式只决定当前显示哪一个——切回图片不用
/// 重选；「恢复默认」才把两个文件一起删掉、模式回 `.none`。
/// 模式先切、文件后选也行：切到图片/视频但还没选文件时，首页显示
/// 默认背景（不崩、不花屏），设置页状态行写明「未选图/未选视频」。
/// 沙盒文件被外部删掉也一样：读不到文件就当没设，显示默认背景。
final class BackgroundStore: ObservableObject {
    static let shared = BackgroundStore()

    /// 背景模式：默认 / 静态图片 / 动态壁纸（视频）。
    enum Mode: String, CaseIterable {
        case none
        case image
        case video
    }

    /// 模式的 UserDefaults 键（无键 = 默认背景）。
    static let modeKey = "lizi.background.mode"
    /// 视频文件名的 UserDefaults 键（存完整文件名，含原扩展名）。
    static let videoFileKey = "lizi.background.videoFile"
    /// 图片文件名（固定 JPEG；视频文件名不固定，见 videoFileKey）。
    static let imageFileName = "background-image.jpg"
    /// 视频默认文件名（没存过键时用它）。
    static let defaultVideoFileName = "background-video.mov"
    /// 图片最长边上限（px）：超过就等比缩小再存，省沙盒空间、
    /// 首页解码也快；没超过的原样存，不放大。
    static let maxImageDimension: CGFloat = 1920
    /// 存图 JPEG 质量。
    static let jpegQuality: CGFloat = 0.85

    /// 当前模式（didSet 写 UserDefaults，重启保留；@Published 让
    /// HomeBackgroundView 与设置页当场重绘）。
    @Published var mode: Mode = BackgroundStore.readMode() {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// 内存里的背景图片（启动时从沙盒读一次；存图成功后当场换，
    /// 不用等下次启动；清掉后置 nil）。
    @Published private(set) var backgroundImage: UIImage?

    /// 当前视频文件名（@Published：设置页状态行与 HomeBackgroundView
    /// 跟它走；无文件时是默认值，但 hasVideoFile 为 false）。
    @Published private(set) var videoFileName: String =
        UserDefaults.standard.string(forKey: BackgroundStore.videoFileKey)
        ?? BackgroundStore.defaultVideoFileName {
        didSet { UserDefaults.standard.set(videoFileName, forKey: Self.videoFileKey) }
    }

    /// r59：启动读盘任务句柄——后台读盘，一次性；读完回主线程发布。
    /// 单例常驻，任务只跑一次就结束，不用等谁取消。
    private var loadTask: Task<Void, Never>?

    private init() {
        // 启动即读盘：图片文件在就读进内存；不在（用户在文件 App 里
        // 删了、或旧版残留）也不崩——mode 照留，首页显示默认背景，
        // 设置页状态行写明未选图/未选视频，用户重选一张就行。
        // r59：读盘不再在 init 里主线程同步等 IO——后台任务读盘，
        // 读完回主线程发布；读盘没完成前 backgroundImage 仍是 nil，
        // 首页先显示默认背景，图到了当场换上（@Published 重绘）。
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if let url = Self.imageFileURL(), let data = try? Data(contentsOf: url) {
                await MainActor.run {
                    self?.backgroundImage = UIImage(data: data)
                }
            }
        }
    }

    // MARK: - 读值（静态口，供 HomeBackgroundView / 设置页用）

    /// 读模式（非法值 / 无键回落默认，不编）。
    static func readMode() -> Mode {
        guard let raw = UserDefaults.standard.string(forKey: modeKey),
              let mode = Mode(rawValue: raw) else { return .none }
        return mode
    }

    /// 背景文件目录（Application Support/lizi.background，不存在就建）。
    static func backgroundDirectory() -> URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("lizi.background", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 图片文件 URL（固定名；文件在不在调用方自己判）。
    static func imageFileURL() -> URL? {
        backgroundDirectory()?.appendingPathComponent(imageFileName)
    }

    /// 当前视频文件 URL（文件不存在回 nil——调用方按「没设视频」处理，
    /// 不崩、不播坏链）。
    var videoFileURL: URL? {
        guard let url = Self.backgroundDirectory()?.appendingPathComponent(videoFileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 视频文件在不在沙盒里。
    var hasVideoFile: Bool { videoFileURL != nil }

    /// 当前真正在显示自定义背景没有（模式有文件才算；没文件 = 默认背景）。
    var hasCustomBackground: Bool {
        switch mode {
        case .none: return false
        case .image: return backgroundImage != nil
        case .video: return hasVideoFile
        }
    }

    /// 设置页状态行文案（当前模式 + 文件在不在，一行说清）。
    var statusText: String {
        switch mode {
        case .none: return "默认背景"
        case .image: return backgroundImage == nil ? "静态图片（未选图）" : "静态图片"
        case .video: return hasVideoFile ? "动态壁纸（视频）" : "动态壁纸（未选视频）"
        }
    }

    /// 当前背景文件的大小文案（设置页状态行用；没文件回 nil）。
    var fileSizeText: String? {
        let url: URL?
        switch mode {
        case .none: return nil
        case .image: url = Self.imageFileURL()
        case .video: url = videoFileURL
        }
        guard let url,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let bytes = size.int64Value
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    // MARK: - 存图 / 存视频 / 清掉

    /// 最长边等比缩小（上限 `maxImageDimension` px；没超原样返回）。
    /// 像素边按 cgImage 取（取不到才用 size × scale 兜底）；渲染保持
    /// 原 scale，不丢 Retina 倍率。
    static func downscaledImage(_ image: UIImage,
                                 maxDimension: CGFloat = maxImageDimension) -> UIImage {
        let scale = image.scale > 0 ? image.scale : 1
        let pxW = CGFloat(image.cgImage?.width ?? Int(image.size.width * scale))
        let pxH = CGFloat(image.cgImage?.height ?? Int(image.size.height * scale))
        let longest = max(pxW, pxH)
        guard longest > maxDimension, longest > 0 else { return image }
        let s = maxDimension / longest
        let newSize = CGSize(width: pxW * s / scale, height: pxH * s / scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 存一张背景图片（设置页 PhotosPicker 读到的 Data）：
    /// 解不开 → false（设置页报「打不开，换一张」）；解得开 → 最长边
    /// 超 1920 等比缩小、JPEG 0.85 原子写盘，内存图当场换、模式切
    /// `.image`，返回 true。只写沙盒文件，不碰相册。
    func saveImageData(_ data: Data) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        let shrunk = Self.downscaledImage(image)
        guard let jpeg = shrunk.jpegData(compressionQuality: Self.jpegQuality),
              let url = Self.imageFileURL() else { return false }
        do {
            try jpeg.write(to: url, options: [.atomic])
        } catch {
            return false
        }
        backgroundImage = shrunk
        mode = .image
        return true
    }

    /// 存一段动态壁纸视频（设置页 PhotosPicker `loadFileRepresentation`
    /// 拿到的临时文件 URL）：原扩展名保存（mov/mp4/m4v；其它/没有
    /// 扩展名按 mov 存，不转码、不重命名内容），拷进沙盒后模式切
    /// `.video`。旧视频文件（不管什么扩展名）先删掉，沙盒里永远只留
    /// 一段视频。拷失败回 false（设置页报「存不下，换一个小一点的」）。
    func saveVideoFile(from tempURL: URL) -> Bool {
        guard let dir = Self.backgroundDirectory() else { return false }
        let fm = FileManager.default
        var ext = tempURL.pathExtension.lowercased()
        if !["mov", "mp4", "m4v"].contains(ext) { ext = "mov" }
        let fileName = "background-video.\(ext)"
        let dest = dir.appendingPathComponent(fileName)
        do {
            // 先清旧视频（换扩展名时旧文件不能留着占地方）。
            if let files = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: nil) {
                for file in files where file.lastPathComponent.hasPrefix("background-video.") {
                    try? fm.removeItem(at: file)
                }
            }
            // 目标已存在（同名）也先删，copyItem 不覆盖。
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: tempURL, to: dest)
        } catch {
            return false
        }
        videoFileName = fileName
        mode = .video
        return true
    }

    /// 恢复默认背景：图片 + 视频文件都删、内存图清掉、模式回 `.none`。
    /// 只删本功能自己的两个文件，不动沙盒里别的东西。
    func clearBackground() {
        let fm = FileManager.default
        if let url = Self.imageFileURL() { try? fm.removeItem(at: url) }
        if let dir = Self.backgroundDirectory(),
           let files = try? fm.contentsOfDirectory(at: dir,
                                                    includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("background-video.") {
                try? fm.removeItem(at: file)
            }
        }
        backgroundImage = nil
        videoFileName = Self.defaultVideoFileName
        mode = .none
    }
}
