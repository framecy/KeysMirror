import Foundation

struct AppProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var bundleIdentifier: String
    var appName: String
    var mappings: [KeyMapping]
    /// v1.5 起新增的宏列表；旧 mappings.json 缺字段时 init(from:) 会回退到空数组。
    var macros: [MacroAction]
    var isEnabled: Bool
    var overlayOpacity: Double
    var showOverlay: Bool

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        mappings: [KeyMapping] = [],
        macros: [MacroAction] = [],
        isEnabled: Bool = true,
        overlayOpacity: Double = 0.5,
        showOverlay: Bool = true
    ) {
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
    }
}