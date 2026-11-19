import Foundation
import UIKit

/// 画廊共享模型（P3-B）。
///
/// 目录与形态类型一律复用 P3-A 的 `StageCatalog` / `StageForm`（Views/Stage/，
/// 本文件不另造目录——P3-B 早期写过一份 GalleryFormsData，已删）：
/// - `StageForm`：formId / name / desc / fileName / isCamera / isClassic。
/// - `StageCatalog.menuList(includeClassic:releaseOnly:)`：展示顺序照抄壳版
///   stageDisplayOrder（504、519 置顶，其余整体倒序）。
/// - `StageCatalog.isAvailable`：文件在 bundle 里（69 个发行版形态全有；
///   其余 590 个只有目录条目、没有文件，壳版同样 404）。
/// - 选中形态的持久化走 `StageCatalog.saveFormId` / `savedFormId`，键
///   `lizi.native.playerMode`（P3-A 定死；不要再写壳版的 `lizi.playerMode`，
///   两处各写各的会串）。
///
/// 本文件只留画廊自己的东西：筛选 tab、版本开关、画廊状态、长廊资源定位。

/// P3-A StageForm 的画廊侧扩展：长廊预览图（forms-labs/previews/<id>.jpg）。
extension StageForm {
    /// 该形态在球面格子里的静态预览图（长廊页同款图；读不到时为 nil，
    /// 格子退回文字格，不编假图）。
    var previewImage: UIImage? {
        GalleryHTMLBundle.previewImage(id: formId)
    }
}

/// 画廊筛选 tab：照抄壳版 stage-pick 的三个 tab。
///
/// - 壳版现状：STAGES 项上没有任何 meta.featured / meta.category / meta.tags，
///   所以「精选」「分类」在壳版里就是空态（文案见 GalleryTabs.emptyCopy）。
///   原生侧不编假数据，同样给空态；以后元数据补上后只改这里的过滤条件。
enum GalleryTab: String, CaseIterable {
    case all = "all"
    case featured = "featured"
    case category = "category"

    var title: String {
        switch self {
        case .all: return "全部"
        case .featured: return "精选"
        case .category: return "分类"
        }
    }

    func matches(_ form: StageForm) -> Bool {
        switch self {
        case .all: return true
        case .featured, .category: return false
        }
    }

    /// 壳版 emptyCopy() 的文案，原样搬过来。
    var emptyTitle: String {
        switch self {
        case .all: return "没有匹配的形态"
        case .featured: return "精选还在整理，先留空"
        case .category: return "分类还在整理，先留空"
        }
    }

    var emptyDetail: String {
        switch self {
        case .all: return "换个关键词试试，或者切回「全部」。"
        case .featured: return "以后会按编辑推荐和形态元数据筛选。"
        case .category: return "以后会按构图、配色、节奏等形态元数据分组。"
        }
    }
}

/// 发行版 / 开发者版：照抄壳版 `lizi.stage.edition`（localStorage 键同名）。
/// 发行版只列用户 2026-11-08 指定的 69 个保留形态；开发者版列全部 659 个。
/// 壳版里切换只能走 localStorage / 控制台；原生侧给一个分段开关，默认发行版。
enum GalleryEdition: String {
    case release = "release"
    case dev = "dev"

    var title: String {
        switch self {
        case .release: return "发行版"
        case .dev: return "全部"
        }
    }
}

/// 画廊共享状态：当前选中的形态 + 版本开关。
///
/// 选中形态的持久化与 P3-A 舞台页共用 `StageCatalog`（键
/// `lizi.native.playerMode`）：画廊选完进舞台，舞台页换形态回来画廊，
/// 两边看到的是同一个「上次用的形态」。
final class StageFormStore: ObservableObject {
    /// 与壳版 STAGE_EDITION_KEY 同名（画廊自己的开关，P3-A 没占这个键）。
    static let editionKey = "lizi.stage.edition"

    /// 当前选中的形态 id（读 P3-A 的保存值；画廊里选完即写回）。
    @Published private(set) var selectedFormId: String
    @Published var edition: GalleryEdition {
        didSet {
            UserDefaults.standard.set(edition.rawValue, forKey: Self.editionKey)
        }
    }

    init() {
        self.selectedFormId = StageCatalog.savedFormId()
        let saved = UserDefaults.standard.string(forKey: Self.editionKey)
        self.edition = GalleryEdition(rawValue: saved ?? "") ?? .release
    }

    /// 当前选中的形态。
    var selectedForm: StageForm? {
        StageCatalog.form(id: selectedFormId)
    }

    /// 当前版本下的展示列表（P3-A menuList，展示顺序照抄壳版）。
    /// classic 不是形态，不进画廊列表（includeClassic: false）。
    var displayList: [StageForm] {
        StageCatalog.menuList(includeClassic: false, releaseOnly: edition == .release)
    }

    /// 选中一个形态并持久化（P3-A 的保存口径，舞台页读同一份）。
    func select(_ form: StageForm) {
        selectedFormId = form.formId
        StageCatalog.saveFormId(form.formId)
    }
}

/// 长廊页 bundle 资源定位（P3-B，P3 r19 集成改过一次：去重）。
///
/// 打包形态：XcodeGen `resources:` 把
/// `ios/Sources/LiziNative/Resources/GalleryHTML/` 整个目录原样拷进 bundle，
/// 形态文件另由单份 `Resources/stages/` 进包：
/// ```
/// GalleryHTML/
///   forms-labs/  index.html + js/ + css/ + assets/ + vendor/ + previews/
/// stages/        69 个 *.html + stages/assets/ 全部 83 个文件（唯一一份）
/// ```
/// - 长廊页的相对路径必须成立：页内用 `../../stages/<file>.html` 进形态
///   （forms-labs/js/app.js stageSrc；原生 bundle 里 forms-labs 比壳版
///   public/ 多嵌了一层 GalleryHTML/，所以是两级 `../`，不是壳版的一级；
///   这是拷贝文件的唯一一处原生适配，见 app.js 里的注释）、用
///   `../vendor/three.module.js` 画球；所以 GalleryWebView 的 readAccess
///   根目录是 bundle 资源根目录（`Resources/` 这一层），不要只给
///   GalleryHTML/——stage iframe 的文档在 `stages/` 下，读权限收窄了
///   它就打不开。
/// - 去重前 `GalleryHTML/stages/` 与 P3-A 的 `Resources/Stages/` 是同一批
///   文件的第二份拷贝（约 27MB）；r19 集成已删掉前者，`stages/` 全小写
///   改名后只剩一份，舞台桥（`StageBridge.fileURL(for:)`）与长廊页共用它。
/// - 舞台文件本身的定位不要走这里，走 P3-A 的 `StageBridge.fileURL(for:)`。
enum GalleryHTMLBundle {
    /// bundle 资源根目录（含 `GalleryHTML/`、`stages/`、`assets/`）。
    /// GalleryWebView 的 readAccess 根（见上）。
    static var rootURL: URL? {
        Bundle.main.resourceURL
    }

    /// 长廊整页：forms-labs/index.html。
    static var formsLabsIndexURL: URL? {
        rootURL?.appendingPathComponent("GalleryHTML/forms-labs/index.html")
    }

    /// 长廊预览图 URL：forms-labs/previews/<id>.jpg。
    static func previewImageURL(id: String) -> URL? {
        rootURL?.appendingPathComponent("GalleryHTML/forms-labs/previews/\(id).jpg")
    }

    /// 长廊预览图（读不到时为 nil，调用方用文字格兜底，不编假图）。
    /// 球面每帧重绘都会问图，用 NSCache 顶住，不反复读盘。
    private static let previewImageCache = NSCache<NSString, UIImage>()

    static func previewImage(id: String) -> UIImage? {
        if let cached = previewImageCache.object(forKey: id as NSString) {
            return cached
        }
        guard let url = previewImageURL(id: id) else { return nil }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        previewImageCache.setObject(image, forKey: id as NSString)
        return image
    }
}
