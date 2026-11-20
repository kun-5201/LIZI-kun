import Foundation

/// 舞台形态目录（P3-A）：1:1 对照壳版 `public/app.js` 的 `STAGES` 数组生成。
///
/// 计数口径（r26，2026-11-20，用户决定：无文件的条目删、不补文件）：
/// - r25 时 `STAGES` 是 676 项 = `classic`（传统播放器，无文件）+ 675 个形态
///   （编号 001–664，中间有空号 281/282/298/299/301）；其中只有 85 个的 HTML
///   文件真实存在于 `public/stages/`，其余 590 个只有目录条目、没有文件。
/// - r26 删掉了这 590 条（只删目录条目，不删 HTML 文件），本文件现剩 86 项 =
///   `classic` + 85 个有文件形态；`releaseIds` / `bundledFileNames` 本来就只含
///   这 85 项，内容未动。选择器、搜索、球面画廊 dev 版随目录自动同步（均 86/85）。
/// - r22 Folia：`F01`–`F16` 是第 22 轮新加的 Folia 舞台（见文件尾的 Folia 段），
///   16 个文件全在磁盘上，全部保留；生成器重跑时必须保留该段。
/// - 生成器口径已改，禁止按旧口径重跑：源头 `public/app.js` 的 `STAGES` 仍含
///   676 项（含已删的 590 条），照旧重跑会把删掉的 590 条复活。重跑前必须先同步
///   源头（把 STAGES 缩到与本文件一致的 86 项，或让生成器只输出有文件形态 +
///   classic），否则不要重跑；未同步前只允许手改本文件。

/// 一个形态（或传统播放器）。
struct StageForm: Identifiable, Hashable {
    var id: String { formId }
    let formId: String
    let name: String
    let desc: String
    /// 形态 HTML 文件名（`Resources/stages/` 下）；classic 为 nil（无文件）。
    let fileName: String?
    /// 相机形态：画面本身要拖动转头，宿主 HUD 切极简（壳版 552 烟雨江南唯一一个）。
    let isCamera: Bool
    var isClassic: Bool { formId == "classic" }
}

enum StageCatalog {

    /// 上次用的形态（`lizi.native.playerMode`；壳版叫 `lizi.playerMode`，
    /// 存 localStorage；原生版存 UserDefaults，键名加 native 前缀以免串库）。
    static let lastStageKey = "lizi.native.playerMode"
    /// 发行版默认形态（壳版 StageHost enter() 在 current 无 url 时回落到 STAGES[1]）。
    static let defaultFormId = "001"

    /// 全目录（`app.js` 顺序，classic 在首位）。
    static let all: [StageForm] = [
        StageForm(formId: "classic", name: "传统播放器", desc: "大封面 + 歌词面板", fileName: nil, isCamera: false),
        StageForm(formId: "001", name: "粒子歌词", desc: "粒子在不同地方聚成词，镜头移过去", fileName: "001-particle-lyrics.html", isCamera: false),
        StageForm(formId: "002", name: "星际歌词", desc: "一路飞过去，一句一句穿过", fileName: "002-starfield-lyrics.html", isCamera: false),
        StageForm(formId: "008", name: "静雪", desc: "雪碰到笔画就粘住，唱完被横风吹散", fileName: "008-snow-lyrics.html", isCamera: false),
        StageForm(formId: "010", name: "余烬", desc: "字是上升气流里的驻波，一直在被重建", fileName: "010-embers-lyrics.html", isCamera: false),
        StageForm(formId: "012", name: "光行洞穴", desc: "每句词是一条在洞里向你飞来的弧面字带", fileName: "012-cave-lyrics.html", isCamera: false),
        StageForm(formId: "020", name: "网格地平线", desc: "字是一叠立在网格上的灯柱，被一道扫描前沿逐个点亮", fileName: "020-grid-horizon-lyrics.html", isCamera: false),
        StageForm(formId: "027", name: "代码雨", desc: "雨不是背景，雨是光栅写入器", fileName: "027-code-rain-lyrics.html", isCamera: false),
        StageForm(formId: "031", name: "CSS 立方体", desc: "字被\"贴\"在自转立方体的面上", fileName: "031-css-cube-lyrics.html", isCamera: false),
        StageForm(formId: "048", name: "谢尔宾斯基", desc: "镜头一直在往空洞里掉", fileName: "048-sierpinski-lyrics.html", isCamera: false),
        StageForm(formId: "066", name: "泼墨黏墙", desc: "词团从画外沿弧线砸上墙，黏住、墨点累积、逐字烧亮、换句被风扫走", fileName: "066-thrown-splat.html", isCamera: false),
        StageForm(formId: "067", name: "电蚀刻痕", desc: "电极头沿笔画行进，电弧烧出熔坑，熔渣火花甩出；字是烧出来的槽，不是画上去的", fileName: "067-arc-etch.html", isCamera: false),
        StageForm(formId: "083", name: "霜花结晶", desc: "窗玻璃上的霜从字心向外结晶，字先出现再被霜盖住", fileName: "083-frost.html", isCamera: false),
        StageForm(formId: "099", name: "生物荧光", desc: "荧光素在液体里扩散，字是一圈**正在扩散的荧光前沿**", fileName: "099-bioluma.html", isCamera: false),
        StageForm(formId: "304", name: "童核", desc: "练习本内页：蜡笔小屋、笑脸太阳、背书包走远的人", fileName: "304-kidcore.html", isCamera: false),
        StageForm(formId: "305", name: "钴蓝网格", desc: "瑞士网格与钴蓝单色纪实：封面做成印版，歌词排成账本", fileName: "305-cobalt-grid.html", isCamera: false),
        StageForm(formId: "306", name: "靶心构成", desc: "包豪斯靶心出血：同心环带被声波撕开一道缺口", fileName: "306-bauhaus-target.html", isCamera: false),
        StageForm(formId: "339", name: "超扁平糖果", desc: "糖果粉柠檬黄的平面色块，糖果兽拖着条纹尾迹", fileName: "339-superflat-candy.html", isCamera: false),
        StageForm(formId: "353", name: "酸柠反设计", desc: "满屏酸柠绿与系统默认字体：丑得诚实，字绝对清楚", fileName: "353-acid-lime.html", isCamera: false),
        StageForm(formId: "359", name: "午夜访客", desc: "1999 年凌晨还亮着灯的个人主页，旋转铬骷髅与星空平铺", fileName: "359-midnight-visitor.html", isCamera: false),
        StageForm(formId: "361", name: "载波残影", desc: "停播后的载波：SMPTE 测试卡隔着弧面玻璃，字幕仍在等一句回应", fileName: "361-dead-air-carrier.html", isCamera: false),
        StageForm(formId: "366", name: "霓虹卡匣", desc: "低分辨率等距像素城，套在 16-bit 卡匣包装里", fileName: "366-neon-cartridge.html", isCamera: false),
        StageForm(formId: "368", name: "图库事故", desc: "带水印的握手图库照压着银河脑，一起失控", fileName: "368-stock-meltdown.html", isCamera: false),
        StageForm(formId: "370", name: "剪刀暴动", desc: "复印纸上的绑架信：愤怒被一个字一个字剪下来", fileName: "370-scissor-riot.html", isCamera: false),
        StageForm(formId: "383", name: "裂肉矩阵", desc: "被拉扯变形的人体网格在 300 拍下撕开，带建模手柄", fileName: "383-flesh-matrix.html", isCamera: false),
        StageForm(formId: "396", name: "七寸留声", desc: "旧唱片店灯下的 45 转纸袖套与慢转黑胶", fileName: "396-crate-label.html", isCamera: false),
        StageForm(formId: "398", name: "银球夜", desc: "镜球撒下满室十字星芒，歌词银白带霓虹辉光", fileName: "398-mirrorball-glitz.html", isCamera: false),
        StageForm(formId: "406", name: "冰隙微光", desc: "万年蓝冰的裂缝里，暖光随低频缓缓流过", fileName: "406-glacial-fissure.html", isCamera: false),
        StageForm(formId: "408", name: "音生晶簇", desc: "低音撑开晶格，鼓点催开光丝：三层自相似的分形晶体", fileName: "408-audio-crystal-bloom.html", isCamera: false),
        StageForm(formId: "413", name: "熔心棘冠", desc: "玻璃心脏在暗处融化，30 根钛棘围成冠", fileName: "413-thorn-glass-heart.html", isCamera: false),
        StageForm(formId: "428", name: "热像监控", desc: "红外人形在监控噪点里逐字升温", fileName: "428-thermal-cctv.html", isCamera: false),
        StageForm(formId: "429", name: "晴日手记", desc: "斜阳晒着衣柜门上的拍立得与手写字", fileName: "429-sunlit-diary.html", isCamera: false),
        StageForm(formId: "443", name: "沉纱", desc: "水中真丝裹住闭目浮游的身体", fileName: "443-silk-cavern.html", isCamera: false),
        StageForm(formId: "504", name: "已发送", desc: "歌词是一条条正在打出来的消息", fileName: "504-imessage-lyric.html", isCamera: false),
        StageForm(formId: "505", name: "棱镜阈限", desc: "刚体棱镜切面，正反蒙版镂空歌词", fileName: "505-metalheart-prism.html", isCamera: false),
        StageForm(formId: "506", name: "偏色过境", desc: "歌词从左边滑过，红蓝错位拖出景深", fileName: "506-chroma-pass.html", isCamera: false),
        StageForm(formId: "508", name: "未来已来", desc: "克莱因蓝与铬字硬切，镜头跟着拍子走", fileName: "508-future-is-here.html", isCamera: false),
        StageForm(formId: "509", name: "活字蒙太奇", desc: "每个字都是一次镜头切换", fileName: "509-kinetic-montage.html", isCamera: false),
        StageForm(formId: "510", name: "积木字墙", desc: "歌词化作积木在三维空间砌成墙", fileName: "510-block-wall.html", isCamera: false),
        StageForm(formId: "517", name: "失焦记忆", desc: "3D纵深穿梭与RGB色差景深的情绪独白", fileName: "517-chromatic-pulse.html", isCamera: false),
        StageForm(formId: "518", name: "瞬态撕裂", desc: "高速甩镜畸变与强拍色相爆闪的卡点舞台", fileName: "518-kinetic-whip.html", isCamera: false),
        StageForm(formId: "519", name: "琉璃幻境", desc: "极光流体着色器与水晶折射消散的梦境", fileName: "519-prism-euphoria.html", isCamera: false),
        StageForm(formId: "520", name: "胶片慢门", desc: "王家卫式抽帧慢门残影与琥珀漏光胶片", fileName: "520-amber-shutter.html", isCamera: false),
        StageForm(formId: "521", name: "赛博挽歌", desc: "信号撕裂错位与3D网格俯冲的故障美学", fileName: "521-glitch-requiem.html", isCamera: false),
        StageForm(formId: "522", name: "深海回响", desc: "深海失重漂浮与水波折射光斑的沉浸舞台", fileName: "522-abyssal-echo.html", isCamera: false),
        StageForm(formId: "524", name: "引力坍缩", desc: "黑洞引力透镜畸变与巨物空间运镜的史诗舞台", fileName: "524-monolith-void.html", isCamera: false),
        StageForm(formId: "525", name: "雨夜霓虹", desc: "车窗雨滴物理折射与都市霓虹散景的夜行舞台", fileName: "525-neon-raindrop.html", isCamera: false),
        StageForm(formId: "540", name: "极地冰洞", desc: "3D万年蓝冰晶洞穴内壁折射与极光穿透", fileName: "540-aurora-ice-cavern.html", isCamera: false),
        StageForm(formId: "542", name: "雷暴云砧", desc: "穿梭万米高空积雨云峡谷与云内紫电闪击", fileName: "542-thunderhead-cumulonimbus.html", isCamera: false),
        StageForm(formId: "552", name: "烟雨江南", desc: "乌篷船摇进无尽烟雨，词句落在前方水上", fileName: "552-ink-wash-rain-pavilion.html", isCamera: true),
        StageForm(formId: "557", name: "千禧液态气球", desc: "Y2K充气镀铬金属泡泡字与酸性镭射贴纸空间", fileName: "557-y2k-chrome-inflatable.html", isCamera: false),
        StageForm(formId: "559", name: "落日合成器公路", desc: "80年代复古未来主义网格山脉、烈日切线与超跑狂飙", fileName: "559-synthwave-outrun-highway.html", isCamera: false),
        StageForm(formId: "561", name: "波普网点分镜", desc: "蜘蛛侠平行宇宙式3D美漫分镜框、CMYK半调网点与拟声词炸裂", fileName: "561-halftone-comic-popart.html", isCamera: false),
        StageForm(formId: "563", name: "体素街机厅", desc: "3D发光体素方块世界崩塌重组与16-Bit粒子爆炸", fileName: "563-pixel-arcade-voxel.html", isCamera: false),
        StageForm(formId: "571", name: "酸性液态镀铬", desc: "90年代Rave酸性流光纹理与扭曲液态银异形雕塑", fileName: "571-acid-techno-liquid-metal.html", isCamera: false),
        StageForm(formId: "572", name: "雷霆荆棘", desc: "3D带刺金属荆棘藤蔓缠绕与高压紫电击穿舞台", fileName: "572-barbed-wire-lightning.html", isCamera: false),
        StageForm(formId: "580", name: "丝绒歌剧院", desc: "3D暗红丝绒舞台帷幕开合、追光灯柱与漫天金箔礼花", fileName: "580-red-velvet-theater-curtain.html", isCamera: false),
        StageForm(formId: "582", name: "隧道远光灯", desc: "深夜无限混凝土公路隧道狂飙、顶部钠灯掠过与远光灯眩光", fileName: "582-concrete-tunnel-headlight.html", isCamera: false),
        StageForm(formId: "588", name: "扳机社闪光帧", desc: "Trigger扳机社夸张广角透视、十字星爆发与黑白手绘冲击帧（Impact Frames）", fileName: "588-trigger-impact-frames.html", isCamera: false),
        StageForm(formId: "590", name: "狂乱漫剪", desc: "顶级日漫MMV动态分镜拼贴、半调网点纸张撕裂与高速残影摇晃", fileName: "590-chainsaw-manga-collage.html", isCamera: false),
        StageForm(formId: "603", name: "折曲红绸", desc: "3D超现实雕塑感红色烤漆金属长带在极简暗黑空间中无限穿插", fileName: "603-folded-metal-ribbon-red.html", isCamera: false),
        StageForm(formId: "604", name: "百叶窗黑色电影", desc: "经典好莱坞黑色电影(Film Noir)百叶窗条纹阴影切割、烟雾缭绕与一抹惊艳主色", fileName: "604-monochrome-noir-rain-blind.html", isCamera: false),
        StageForm(formId: "614", name: "非欧传送门", desc: "穿过悬浮3D画框直接看到并冲入完全不同色调与几何形态的平行空间", fileName: "614-non-euclidean-portal-rooms.html", isCamera: false),
        StageForm(formId: "617", name: "水底教室", desc: "沉没在清澈深水中的青春教室课桌椅、丁达尔水波阳光与漂浮气泡", fileName: "617-underwater-classroom-sunbeam.html", isCamera: false),
        StageForm(formId: "621", name: "末日高架桥", desc: "废土斜阳下断裂的3D城市跨海高架桥、漫天蒲公英/辐射光尘与孤独剪影", fileName: "621-apocalyptic-sunset-overpass.html", isCamera: false),
        StageForm(formId: "627", name: "墨线暴走", desc: "红底白环剪纸，黑墨字每句换机位", fileName: "627-ink-line-rush.html", isCamera: false),
        StageForm(formId: "628", name: "纸页快闪", desc: "一个词一页，整页纸跟着快切", fileName: "628-paper-flash.html", isCamera: false),
        StageForm(formId: "629", name: "运动路径", desc: "黑字沿轨迹飞行，彩色线条乱穿", fileName: "629-motion-path.html", isCamera: false),
        StageForm(formId: "631", name: "星轨跟拍", desc: "镜头追着歌词，星空真实视差", fileName: "631-stellar-tracking.html", isCamera: false),
        StageForm(formId: "663", name: "弹簧诗行", desc: "每字一条独立弹簧，逐字错帧破土回弹，五组空间构图随句轮换，字缘微光与液态高光条贴在壁纸引擎背景上运行", fileName: "663-spring-verse.html", isCamera: false),
        // ---- r22 Folia 舞台（F01–F16）：Folia 18 个模式去重后剩 16 个；
        // cappella（撞 504 iMessage）与 still（撞 classic 静态歌词）未加。
        // 只学形态与流程、按 Lizi 协议独立重写，见各 HTML 文件头的 AGPL 来源注释。
        StageForm(formId: "F01", name: "商籁", desc: "海报外框 + 每句一切镜头的 MG 歌词 PV", fileName: "F01-folia-sonnet.html", isCamera: false),
        StageForm(formId: "F02", name: "凝彩", desc: "色块分割构图，鼓点墨染晕开，景深视差", fileName: "F02-folia-tempera.html", isCamera: false),
        StageForm(formId: "F03", name: "绘光", desc: "体积光柱 + 雾 + 线稿场景，歌词被光照亮", fileName: "F03-folia-lumiere.html", isCamera: false),
        StageForm(formId: "F04", name: "花火", desc: "亮色块歌词，烟花与贴纸沿词绽放", fileName: "F04-folia-hanabi.html", isCamera: false),
        StageForm(formId: "F05", name: "町景", desc: "微缩街角，歌词写在 LED 招牌与跑马灯上", fileName: "F05-folia-machi.html", isCamera: false),
        StageForm(formId: "F06", name: "隐喻", desc: "墨团融合 + 半调网屏，每句硬切机位", fileName: "F06-folia-metaphor.html", isCamera: false),
        StageForm(formId: "F07", name: "流光", desc: "单行居中歌词，逐字点亮", fileName: "F07-folia-liuguang.html", isCamera: false),
        StageForm(formId: "F08", name: "心象", desc: "字符散落成云，焦点字被光圈套住", fileName: "F08-folia-cadenza.html", isCamera: false),
        StageForm(formId: "F09", name: "云阶", desc: "歌词逐行向右下错落成阶梯", fileName: "F09-folia-partita.html", isCamera: false),
        StageForm(formId: "F10", name: "浮名", desc: "整首歌词排成文章，镜头穿行其中", fileName: "F10-folia-fume.html", isCamera: false),
        StageForm(formId: "F11", name: "倾诉", desc: "主行水平，副行倾斜", fileName: "F11-folia-tilt.html", isCamera: false),
        StageForm(formId: "F12", name: "回环", desc: "倾斜椭圆轨道，歌词骑环而行", fileName: "F12-folia-claddagh.html", isCamera: false),
        StageForm(formId: "F13", name: "莫奈", desc: "左侧关键字，右侧立绘的海报舞台", fileName: "F13-folia-monet.html", isCamera: false),
        StageForm(formId: "F14", name: "时计", desc: "左侧齿轮钟表盘，右侧歌词", fileName: "F14-folia-pendolo.html", isCamera: false),
        StageForm(formId: "F15", name: "镜台", desc: "多层景深歌词穿行，拍点涟漪", fileName: "F15-folia-diorama.html", isCamera: false),
        StageForm(formId: "F16", name: "雾笺", desc: "雨夜雾窗，指尖写字抹开雾面", fileName: "F16-folia-nebbia.html", isCamera: false),
    ]

    /// 壳版发行版白名单 `STAGE_RELEASE_ORDER`（顺序即白名单顺序）。
    static let releaseIds: [String] = ["504", "519", "001", "002", "008", "010", "012", "020", "027", "031", "048", "066", "067", "083", "099", "304", "305", "306", "339", "353", "359", "361", "366", "368", "370", "383", "396", "398", "406", "408", "413", "428", "429", "443", "505", "506", "508", "509", "510", "517", "518", "520", "521", "522", "524", "525", "540", "542", "552", "557", "559", "561", "563", "571", "572", "580", "582", "588", "590", "603", "604", "614", "617", "621", "627", "628", "629", "631", "663", "F01", "F02", "F03", "F04", "F05", "F06", "F07", "F08", "F09", "F10", "F11", "F12", "F13", "F14", "F15", "F16"]

    /// 已打进原生 bundle 的形态文件名（= 磁盘上真实存在的 85 个文件）。
    static let bundledFileNames: Set<String> = ["001-particle-lyrics.html", "002-starfield-lyrics.html", "008-snow-lyrics.html", "010-embers-lyrics.html", "012-cave-lyrics.html", "020-grid-horizon-lyrics.html", "027-code-rain-lyrics.html", "031-css-cube-lyrics.html", "048-sierpinski-lyrics.html", "066-thrown-splat.html", "067-arc-etch.html", "083-frost.html", "099-bioluma.html", "304-kidcore.html", "305-cobalt-grid.html", "306-bauhaus-target.html", "339-superflat-candy.html", "353-acid-lime.html", "359-midnight-visitor.html", "361-dead-air-carrier.html", "366-neon-cartridge.html", "368-stock-meltdown.html", "370-scissor-riot.html", "383-flesh-matrix.html", "396-crate-label.html", "398-mirrorball-glitz.html", "406-glacial-fissure.html", "408-audio-crystal-bloom.html", "413-thorn-glass-heart.html", "428-thermal-cctv.html", "429-sunlit-diary.html", "443-silk-cavern.html", "504-imessage-lyric.html", "505-metalheart-prism.html", "506-chroma-pass.html", "508-future-is-here.html", "509-kinetic-montage.html", "510-block-wall.html", "517-chromatic-pulse.html", "518-kinetic-whip.html", "519-prism-euphoria.html", "520-amber-shutter.html", "521-glitch-requiem.html", "522-abyssal-echo.html", "524-monolith-void.html", "525-neon-raindrop.html", "540-aurora-ice-cavern.html", "542-thunderhead-cumulonimbus.html", "552-ink-wash-rain-pavilion.html", "557-y2k-chrome-inflatable.html", "559-synthwave-outrun-highway.html", "561-halftone-comic-popart.html", "563-pixel-arcade-voxel.html", "571-acid-techno-liquid-metal.html", "572-barbed-wire-lightning.html", "580-red-velvet-theater-curtain.html", "582-concrete-tunnel-headlight.html", "588-trigger-impact-frames.html", "590-chainsaw-manga-collage.html", "603-folded-metal-ribbon-red.html", "604-monochrome-noir-rain-blind.html", "614-non-euclidean-portal-rooms.html", "617-underwater-classroom-sunbeam.html", "621-apocalyptic-sunset-overpass.html", "627-ink-line-rush.html", "628-paper-flash.html", "629-motion-path.html", "631-stellar-tracking.html", "663-spring-verse.html", "F01-folia-sonnet.html", "F02-folia-tempera.html", "F03-folia-lumiere.html", "F04-folia-hanabi.html", "F05-folia-machi.html", "F06-folia-metaphor.html", "F07-folia-liuguang.html", "F08-folia-cadenza.html", "F09-folia-partita.html", "F10-folia-fume.html", "F11-folia-tilt.html", "F12-folia-claddagh.html", "F13-folia-monet.html", "F14-folia-pendolo.html", "F15-folia-diorama.html", "F16-folia-nebbia.html"]

    /// 该形态能不能在原生版里播（文件在 bundle 里）。
    static func isAvailable(_ form: StageForm) -> Bool {
        guard let fileName = form.fileName else { return false }
        return bundledFileNames.contains(fileName)
    }

    static func form(id: String) -> StageForm? {
        all.first { $0.formId == id }
    }

    /// 壳版 `stageRankOf`：发行版内按白名单顺序，其余按原顺序排到后面。
    static func rank(of form: StageForm) -> Int {
        if let i = releaseIds.firstIndex(of: form.formId) { return i }
        let orig = all.firstIndex(of: form) ?? 0
        return 10000 + orig
    }

    /// 壳版 `stageDisplayOrder`：classic 第一，504、519 置顶，其余整体倒序。
    static func displayOrder(_ list: [StageForm]) -> [StageForm] {
        var head: [StageForm] = []
        if let classic = list.first(where: { $0.isClassic }) { head.append(classic) }
        for id in ["504", "519"] {
            if let s = list.first(where: { $0.formId == id }) { head.append(s) }
        }
        let rest = list.filter { !$0.isClassic && $0.formId != "504" && $0.formId != "519" }.reversed()
        return head + Array(rest)
    }

    /// 壳版 `stageMenuList(includeClassic:)`：发行版只含白名单 85 个；
    /// 全部目录 = 开发版全集。返回的都是展示顺序（`displayOrder` 之后）。
    static func menuList(includeClassic: Bool, releaseOnly: Bool) -> [StageForm] {
        let list = all.filter { form in
            if form.fileName != nil {
                return !releaseOnly || releaseIds.contains(form.formId)
            }
            return includeClassic
        }
        return displayOrder(list.sorted { rank(of: $0) < rank(of: $1) })
    }

    /// 壳版长廊搜索 `stageMatches`：编号 + 形态名 + 描述子串匹配（不区分大小写）。
    static func matches(_ form: StageForm, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        let hay = (form.formId + " " + form.name + " " + form.desc).lowercased()
        return hay.contains(q)
    }

    /// 读上次用的形态 id（没有 / 不可用时回默认 001）。
    static func savedFormId() -> String {
        let v = UserDefaults.standard.string(forKey: lastStageKey) ?? ""
        if let form = form(id: v), isAvailable(form) { return v }
        return defaultFormId
    }

    static func saveFormId(_ id: String) {
        UserDefaults.standard.set(id, forKey: lastStageKey)
    }
}

// 生成器（r26 已冻结）：不要按旧口径重跑本文件。
// 源头 public/app.js 的 STAGES 仍是 676 项（含 r26 已删的 590 条无文件条目），
// 照旧重跑会把删掉的条目全部复活。重跑前必须先同步源头（STAGES 缩到与本文件
// 一致的 86 项，或生成器只输出有文件形态 + classic）；未同步前只允许手改本文件。
