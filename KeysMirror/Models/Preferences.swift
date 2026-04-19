import Foundation

/// 全局偏好（与 mappings.json 分离，避免数据耦合）。
/// 当前只承载全局开关 hotkey；后续新增项追加字段即可。
struct Preferences: Codable {
    var globalToggleHotkey: HotkeyConfig?

    init(globalToggleHotkey: HotkeyConfig? = .defaultToggle) {
        self.globalToggleHotkey = globalToggleHotkey
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
