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

    init(
        globalToggleHotkey: HotkeyConfig? = .defaultToggle,
        hudCycleHotkey: HotkeyConfig? = .defaultHUDCycle,
        showInDock: Bool = false
    ) {
        self.globalToggleHotkey = globalToggleHotkey
        self.hudCycleHotkey = hudCycleHotkey
        self.showInDock = showInDock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.globalToggleHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .globalToggleHotkey)
        // 旧 preferences.json 没有这个字段 → 用默认 ⌃⇧H
        self.hudCycleHotkey = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hudCycleHotkey) ?? .defaultHUDCycle
        self.showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
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
