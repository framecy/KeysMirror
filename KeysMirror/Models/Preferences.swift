import AppKit
import Foundation

/// 全局偏好（与 mappings.json 分离，避免数据耦合）。
/// 当前只承载全局开关 hotkey；后续新增项追加字段即可。
struct Preferences: Codable {
    var globalToggleHotkey: HotkeyConfig?
    /// 游戏内 HUD 三态循环热键（v1.6），默认 ⌃⇧H
    var hudCycleHotkey: HotkeyConfig?

    /// 是否在 Dock 中显示。
    /// App 本体是 LSUIElement（菜单栏常驻），默认不占 Dock；打开后运行时切成 .regular，
    /// Dock 里就有图标可以点。菜单栏面板与主窗设置菜单共用这一个字段，避免两处状态不同步。
    var showInDock: Bool

    /// 目标不在前台时，宏该怎么办。默认「仅前台执行」，理由见 `BackgroundMacroPolicy`。
    var backgroundMacroPolicy: BackgroundMacroPolicy

    init(
        globalToggleHotkey: HotkeyConfig? = .defaultToggle,
        hudCycleHotkey: HotkeyConfig? = .defaultHUDCycle,
        showInDock: Bool = false,
        backgroundMacroPolicy: BackgroundMacroPolicy = .frontmostOnly
    ) {
        self.globalToggleHotkey = globalToggleHotkey
        self.hudCycleHotkey = hudCycleHotkey
        self.showInDock = showInDock
        self.backgroundMacroPolicy = backgroundMacroPolicy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.globalToggleHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .globalToggleHotkey)
        // 旧 preferences.json 没有这个字段 → 用默认 ⌃⇧H
        self.hudCycleHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hudCycleHotkey) ?? .defaultHUDCycle
        self.showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        // v1.7.1 新增。旧配置文件里没有 → 落到 .frontmostOnly，
        // 也就是把 v1.7.0 那个「后台也跑、代价是抢焦点」的行为默认关掉。
        self.backgroundMacroPolicy = try c.decodeIfPresent(BackgroundMacroPolicy.self, forKey: .backgroundMacroPolicy)
            ?? .frontmostOnly
    }
}

/// 目标 app 不在前台时宏的行为策略。
///
/// 为什么需要这个开关：iOS-on-Mac 游戏的点击必须走 session 层投递，而 session 层事件
/// 按「点到了谁的窗口」路由——被点到的后台窗口会被 Window Server 激活到前台。这一点
/// **无法从应用侧阻止**（`eventTargetUnixProcessID` 标记实测拦不住），点完再 `activate`
/// 抢回来只是补丁，必然留下焦点抖动的窗口期。
///
/// 与其让用户遇到「宏怎么老把游戏翻上来」而困惑，不如默认老实一点：目标不在前台就
/// 跳过这一步，用户切回去自动续跑。真需要挂机的人自己打开另一档，并且知道代价。
///
/// ⚠️ 这个代价**只存在于 iOS-on-Mac 应用**。原生 macOS App 走 `postToPid`，事件直接进
/// 目标进程：不动光标、不激活窗口、也不受遮挡影响，后台点击对用户零副作用。
/// 因此「仅前台执行」不约束原生 App——见 `MacroRunner.shouldSkipBecauseBackground`。
enum BackgroundMacroPolicy: String, Codable, CaseIterable, Hashable {
    /// 仅在目标处于前台时执行（默认）。**仅约束 iOS-on-Mac 应用**：它们在后台 → 跳过该步，
    /// 不停止宏。原生 macOS App 不受此档约束，后台照跑。
    case frontmostOnly
    /// 允许后台执行，接受「点击可能把目标窗口切到前台」的代价。
    case allowActivation

    var title: String {
        switch self {
        case .frontmostOnly: return "仅前台执行"
        case .allowActivation: return "允许后台执行"
        }
    }

    var detail: String {
        switch self {
        case .frontmostOnly:
            return "普通 Mac 应用后台照跑；手游（iOS-on-Mac）不在最前面时自动跳过，切回去继续。都不会打断你手上的事。"
        case .allowActivation:
            return "目标在后台也点。iOS-on-Mac 游戏会被系统切到前台，这是系统限制，无法避免。"
        }
    }
}

/// 一个键盘组合（仅键盘；不允许鼠标按键作为全局 hotkey 以避免误触）
struct HotkeyConfig: Codable, Hashable {
    var keyCode: UInt16
    /// CG 规范化后的修饰位值（由 ModifierHelper.cleanModifiers 产生）
    var modifiers: UInt64

    /// 默认 ⌃⇧K：在不与系统快捷键冲突的前提下足够小众
    static let defaultToggle = HotkeyConfig(
        keyCode: 0x28, // kVK_ANSI_K
        modifiers: 0x40000 | 0x20000 // maskControl | maskShift
    )

    /// 默认 ⌃⇧H：切换游戏内 HUD 的完整 / 紧凑 / 隐藏
    static let defaultHUDCycle = HotkeyConfig(
        keyCode: 0x04, // kVK_ANSI_H
        modifiers: 0x40000 | 0x20000
    )
}

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published private(set) var preferences: Preferences

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
        self.fileURL = fileURL ?? Self.defaultFileURL()

        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? decoder.decode(Preferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = Preferences()
        }
    }

    /// 把「是否在 Dock 显示」应用到当前进程。
    /// 切到 .regular 时补一次 activate：否则 Dock 图标出现了但 App 仍在后台，看着像没反应。
    func applyDockVisibility() {
        let show = preferences.showInDock
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate(ignoringOtherApps: true) }
    }

    func update(_ transform: (inout Preferences) -> Void) {
        var copy = preferences
        transform(&copy)
        preferences = copy
        save()
    }

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(preferences)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KeysMirror failed to save preferences: \(error.localizedDescription)")
        }
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("KeysMirror", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }
}
