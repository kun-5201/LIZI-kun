import CoreGraphics
import Foundation

/// 球面画廊的投影数学：1:1 移植壳版 app.js 里 stage-pick 一节的常量与公式
///（PICK_*；buildSphere / renderSphere / pickViewport / 拖动灵敏度）。
///
/// 壳版做法回顾（只取行为，不搬 DOM）：
/// - 33 × 19 = 627 个槽位（11 组 × 每组 3 格 × 19 行），当前发行版 69 个形态
///   只填前面的槽位；奇偶行用 [2,1,1] / [1,1,2] 两种 2:1 + 1:1 混排。
/// - 填槽顺序：行从赤道向两极铺（PICK_ROW_ORDER），组按 [5,6,4,7,3,8,2,9,1,10,0]
///   从正面开始，这样搜索只剩几个结果时它们也在镜头正前方。
/// - 相机在 z = 2.4R，焦距 1.4R，正面格子的透视比例正好是 1，越靠边越小；
///   背面（z2 <= 0.02）不渲染；透明度随离镜头角衰减，最低 0.1。
/// - 拖动：yaw 无限取模，pitch 夹在 ±80°；松手后按最后速度惯性衰减
///  （0.9^(dt/16.7)）；点按与拖动用 6pt 阈值区分，拖完 360ms 内屏蔽点击。
/// - 原生适配：壳版的 headerH（90/180）是为页面自己的页头留的；原生侧页头
///   在球面区域之外，所以球心直接取区域中心 cy = vh/2，其余公式不变。
enum SphereMath {
    static let rows = 19
    static let groups = 11
    /// 每组 3 格的经度总宽 = 4A，组间再留 0.55A。
    static let angleA = (Double.pi * 2) / (Double(groups) * 4.55)
    static let latStep = Double.pi / Double(rows)
    static let rowPatterns = [[2, 1, 1], [1, 1, 2]]
    static let groupGap = angleA * 0.55
    static let hRatio = 0.84
    static let pitchMax = (80 * Double.pi) / 180
    /// 只给 cos(离镜头角) > 0.34 的格子挂载（约 70°）——原生侧指「正面格子」。
    static let maxAngle = 0.34
    /// 壳版球面格子的虚拟基座尺寸（160×176，宽格 320），缩放换算用。
    static let baseSquareWidth: CGFloat = 160
    static let baseHeight: CGFloat = 176
    static let baseWideWidth: CGFloat = 320
    /// 相机距离 / 焦距（单位：球半径 R）。
    static let cameraDistance = 2.4
    static let focalLength = 1.4

    /// 行铺放顺序：赤道（第 9 行）起，向两极交替展开。
    static let rowOrder: [Int] = {
        let mid = (rows - 1) / 2
        var out = [mid]
        for d in 1..<rows {
            if mid + d < rows { out.append(mid + d) }
            if mid - d >= 0 { out.append(mid - d) }
        }
        return out
    }()

    /// 组铺放顺序：从正面（第 5 组）起，向两侧展开。
    static let groupOrder = [5, 6, 4, 7, 3, 8, 2, 9, 1, 10, 0]

    /// 球面上的一个槽位（与一个形态一一对应）。
    struct Slot: Hashable {
        let formIndex: Int
        let lon: Double
        let lat: Double
        let wide: Bool
        let cosLat: Double
        /// 单位球面坐标。
        let x: Double
        let y: Double
        let z: Double
    }

    /// 按壳版 buildSphere 的顺序给形态分槽（list 顺序 = 展示顺序）。
    static func slots(count: Int) -> [Slot] {
        var out: [Slot] = []
        var idx = 0
        for row in rowOrder where idx < count {
            let lat = Double.pi / 2 - (Double(row) + 0.5) * latStep
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let pattern = rowPatterns[row % 2]
            for g in groupOrder where idx < count {
                var cellStart = -Double.pi + Double(g) * (4 * angleA + groupGap)
                for k in 0..<3 where idx < count {
                    let wide = pattern[k] == 2
                    let widthAng = (wide ? 2 : 1) * angleA
                    let lon = cellStart + widthAng / 2
                    cellStart += widthAng
                    out.append(Slot(
                        formIndex: idx,
                        lon: lon, lat: lat, wide: wide, cosLat: cosLat,
                        x: cosLat * sin(lon), y: sinLat, z: cosLat * cos(lon)
                    ))
                    idx += 1
                }
            }
        }
        return out
    }

    /// 投影结果（壳版 renderSphere 里每格算出的那一组值）。
    struct Projection {
        /// 是否在正面、应渲染（z2 > 0.02 且在视口内由调用方再判断）。
        let visible: Bool
        let center: CGPoint
        let size: CGSize
        let opacity: Double
        let zIndex: Double
        /// 绕 Y 的倾角（度，壳版 rotateY，夹在 ±48°）。
        let rotateYDegrees: Double
        /// 离镜头角的 cos 值（z2；原生侧用它筛「正面格子」）。
        let facing: Double
    }

    /// 球半径 R（壳版 pickViewport；mobile 指 vw <= 760 的窄屏）。
    static func sphereRadius(viewport: CGSize) -> CGFloat {
        let mobile = viewport.width <= 760
        if mobile {
            return max(viewport.width * 0.95, viewport.height * 0.62)
        }
        return max(viewport.width * 0.62, viewport.height * 0.86)
    }

    /// yaw 灵敏度（壳版 pickYawSens）：2π / max(420, min(vw,1600)*1.7)。
    static func yawSensitivity(viewportWidth: CGFloat) -> Double {
        (Double.pi * 2) / max(420, min(Double(viewportWidth), 1600) * 1.7)
    }

    /// pitch 灵敏度（壳版 pickPitchSens）：π / max(520, vh*1.6)。
    static func pitchSensitivity(viewportHeight: CGFloat) -> Double {
        Double.pi / max(520, Double(viewportHeight) * 1.6)
    }

    /// 把一个槽位投影到屏幕（壳版 renderSphere 的逐格公式，原样搬）。
    static func project(slot: Slot, yaw: Double, pitch: Double, viewport: CGSize) -> Projection {
        let radius = sphereRadius(viewport: viewport)
        let cx = viewport.width / 2
        let cy = viewport.height / 2
        let distance = radius * cameraDistance
        let focal = radius * focalLength
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        let cosPitch = cos(pitch)
        let sinPitch = sin(pitch)
        let rowH = radius * CGFloat(latStep) * CGFloat(hRatio)

        let x1 = slot.x * cosYaw - slot.z * sinYaw
        let z1 = slot.x * sinYaw + slot.z * cosYaw
        let y2 = slot.y * cosPitch - z1 * sinPitch
        let z2 = slot.y * sinPitch + z1 * cosPitch

        guard z2 > 0.02 else {
            return Projection(visible: false, center: .zero, size: .zero,
                              opacity: 0, zIndex: 0, rotateYDegrees: 0, facing: z2)
        }
        let p = focal / (distance - CGFloat(z2) * radius)
        let sx = cx + CGFloat(x1) * radius * p
        let sy = cy - CGFloat(y2) * radius * p
        var dLon = slot.lon - yaw
        dLon = (dLon + Double.pi).truncatingRemainder(dividingBy: Double.pi * 2)
        if dLon < 0 { dLon += Double.pi * 2 }
        dLon -= Double.pi
        let cosDLon = max(0.04, cos(dLon))
        let w = (slot.wide ? 2 : 1) * radius * CGFloat(angleA)
            * max(0.1, CGFloat(slot.cosLat)) * CGFloat(cosDLon) * p
        let h = rowH * max(0.12, abs(cos(CGFloat(slot.lat) - CGFloat(pitch)))) * p
        let opacity = min(1, max(0.1, (z2 - 0.02) / 0.22))
        let zIndex = 1000 + z2 * 1000
        let rotateY = max(-48, min(48, dLon * (180 / Double.pi) * 0.5))
        return Projection(
            visible: true,
            center: CGPoint(x: sx, y: sy),
            size: CGSize(width: w, height: h),
            opacity: opacity, zIndex: zIndex,
            rotateYDegrees: rotateY, facing: z2
        )
    }

    /// yaw 归一化到 [-π, π]（壳版 normalizeYaw）。
    static func normalizedYaw(_ yaw: Double) -> Double {
        var y = (yaw + Double.pi).truncatingRemainder(dividingBy: Double.pi * 2)
        if y < 0 { y += Double.pi * 2 }
        return y - Double.pi
    }

    /// pitch 夹在 ±80°（壳版 clampPitch）。
    static func clampedPitch(_ pitch: Double) -> Double {
        max(-pitchMax, min(pitchMax, pitch))
    }
}
