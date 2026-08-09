import Foundation

struct AppProfile: Codable, Identifiable, Hashable {
    /// 可变是为了让导入能「整份复制 incoming、只改 id」——见 MappingStore.importProfiles。
    /// 逐字段手工构造的老写法每加一个新字段就漏一次，是 HUD 设置在导入时丢失的根因。
    var id: UUID
    var bundleIdentifier: String
    var appName: String
    var mappings: [KeyMapping]
    /// v1.5 起新增的宏列表；旧 mappings.json 缺字段时 init(from:) 会回退到空数组。
    var macros: [MacroAction]
    var isEnabled: Bool
    var overlayOpacity: Double
    var showOverlay: Bool

    // MARK: - 游戏内 HUD（v1.6）
    /// 目标 app 前台时，在其窗口内叠加状态 + 最近 10 条日志。详见 docs/UI-Redesign.md 6.7。
    /// 全部字段解码用 decodeIfPresent 兜底，旧 mappings.json / .playmap 正常读取。
    ///
    /// 不含透明度字段：HUD 面板固定不透明（`floatingSurface` 实色底），
    /// 与全局「不使用透明效果」的规范一致。v1.6 的 `hudOpacity` 字段已移除
    /// （`decodeIfPresent` 之下，旧数据里残留的这个字段会被安全忽略）。
    var showHUD: Bool
    var hudCorner: HUDCorner
    var hudMode: HUDMode
    var hudLogFilter: HUDLogFilter

    /// 每应用的按压时长（毫秒）。nil = 用全局默认 40ms。
    ///
    /// 为什么要能改：这个值同时决定「点得稳不稳」和「光标闪多久」。按帧轮询输入的游戏
    /// （Unity / UE）需要按压跨过至少一帧才收得到，低了点击直接失效；而对 iOS-on-Mac 目标，
    /// 这段时间正是光标被隐藏的时间，高了就更晃眼。不同游戏的底线不一样，
    /// 40ms 只是所有目标共用的一个折中值——真遇到「点不中」或「太晃」时得能自己调。
    var clickDwellMs: Int?

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        mappings: [KeyMapping] = [],
        macros: [MacroAction] = [],
        isEnabled: Bool = true,
        overlayOpacity: Double = 0.5,
        showOverlay: Bool = true,
        showHUD: Bool = true,
        hudCorner: HUDCorner = .topTrailing,
        hudMode: HUDMode = .full,
        hudLogFilter: HUDLogFilter = .actionsOnly,
        clickDwellMs: Int? = nil
    ) {
        self.clickDwellMs = clickDwellMs
        self.showHUD = showHUD
        self.hudCorner = hudCorner
        self.hudMode = hudMode
        self.hudLogFilter = hudLogFilter
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.mappings = mappings
        self.macros = macros
        self.isEnabled = isEnabled
        self.overlayOpacity = overlayOpacity
        self.showOverlay = showOverlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.bundleIdentifier = try c.decode(String.self, forKey: .bundleIdentifier)
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? ""
        self.mappings = try c.decodeIfPresent([KeyMapping].self, forKey: .mappings) ?? []
        self.macros = try c.decodeIfPresent([MacroAction].self, forKey: .macros) ?? []
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.overlayOpacity = try c.decodeIfPresent(Double.self, forKey: .overlayOpacity) ?? 0.5
        self.showOverlay = try c.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? true
        self.showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? true
        self.hudCorner = try c.decodeIfPresent(HUDCorner.self, forKey: .hudCorner) ?? .topTrailing
        self.hudMode = try c.decodeIfPresent(HUDMode.self, forKey: .hudMode) ?? .full
        self.hudLogFilter = try c.decodeIfPresent(HUDLogFilter.self, forKey: .hudLogFilter) ?? .actionsOnly
        // v1.7.1 新增；旧配置 / 旧 .playmap 缺字段 → nil → 走全局默认 40ms，行为不变
        self.clickDwellMs = try c.decodeIfPresent(Int.self, forKey: .clickDwellMs)
    }

    /// 传给 ClickSimulator 的按压时长（秒）。未设置返回 nil，由 ClickSimulator 用全局默认。
    var clickDwellSeconds: TimeInterval? {
        clickDwellMs.map { TimeInterval($0) / 1000.0 }
    }
}

/// HUD 贴靠的窗口角
enum HUDCorner: String, Codable, CaseIterable, Hashable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var title: String {
        switch self {
        case .topLeading: return "左上"
        case .topTrailing: return "右上"
        case .bottomLeading: return "左下"
        case .bottomTrailing: return "右下"
        }
    }
}

/// HUD 显示形态：完整（状态 + 日志）/ 紧凑（只留状态一行）/ 隐藏
enum HUDMode: String, Codable, CaseIterable, Hashable {
    case full, compact, hidden

    var title: String {
        switch self {
        case .full: return "完整"
        case .compact: return "紧凑"
        case .hidden: return "隐藏"
        }
    }

    /// ⌃⇧H 在三态间循环
    var next: HUDMode {
        switch self {
        case .full: return .compact
        case .compact: return .hidden
        case .hidden: return .full
        }
    }
}

/// HUD 日志过滤：默认只显示动作与告警，TRACE/INFO 太吵
enum HUDLogFilter: String, Codable, CaseIterable, Hashable {
    case actionsOnly, all

    var title: String {
        switch self {
        case .actionsOnly: return "仅动作"
        case .all: return "全部"
        }
    }
}