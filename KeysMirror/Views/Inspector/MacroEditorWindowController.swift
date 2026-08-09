import AppKit
import SwiftUI

/// 宏编辑器的独立窗口。
///
/// 宏不适合塞在侧边 Inspector 里：一个宏动辄七八步，每步展开后有延迟 / 连击 / 漂移 /
/// 位置来源四组控件，340–460pt 的侧栏怎么排都是挤的，还要和主列表抢横向空间。
/// 独立窗口给足宽度和高度，也允许同时开着主窗对照。
///
/// 一个宏对应一个窗口（按 macro id 去重），已打开则前置。
@MainActor
final class MacroEditorWindowController {
    static let shared = MacroEditorWindowController()

    private static let defaultSize = CGSize(width: 620, height: 780)
    private static let minSize = CGSize(width: 520, height: 560)

    private var windows: [String: NSWindow] = [:]
    private var closeObservers: [String: NSObjectProtocol] = [:]
    /// 上一次因录制而隐藏的窗口 key（A2：录制结束只恢复这一个，不把其它宏窗口一起拽到最前）
    private var hiddenForRecording: String?

    private init() {}

    /// 打开（或前置）某个宏的编辑窗口。`macro == nil` 表示新建。
    func open(profile: AppProfile, macro: MacroAction?) {
        let key = macro.map(Self.key(for:)) ?? Self.draftKey()

        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = makeWindow(title: macro.map { "宏 · \($0.label)" } ?? "新建宏")

        // A1：草稿第一次自动保存拿到真实 id 后，把这扇窗口从 draft key 重绑到 macro id，
        // 否则随后从列表点「编辑」同一条宏会判定成「没开过」，另开一个窗口，
        // 两个 view model 各自即时保存、互相覆盖。
        let content = MacroInspector(profile: profile, macro: macro) { [weak self] savedMacro in
            self?.rebind(from: key, to: Self.key(for: savedMacro), window: window, title: "宏 · \(savedMacro.label)")
        }
        window.contentView = NSHostingView(rootView: content.frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height))

        observeClose(of: window, key: key)
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 宏被删除时关掉对应窗口，避免编辑一个已经不存在的东西
    func close(macroId: UUID) {
        let key = Self.key(for: macroId)
        windows[key]?.close()
        forget(key)
    }

    /// 录制期间要让位给目标 app（与主窗同样的处理）。
    /// 只记住"最上层的那一扇"——多个宏窗口同时开着时，只有用户正在操作的那扇会去录制，
    /// 其余的没理由被隐藏又被拽回最前。
    func hideForRecording() {
        guard hiddenForRecording == nil else { return }
        guard let (key, window) = windows.first(where: { $0.value.isKeyWindow }) else { return }
        window.orderOut(nil)
        hiddenForRecording = key
    }

    func restoreFromRecording() {
        guard let key = hiddenForRecording else { return }
        hiddenForRecording = nil
        windows[key]?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 测试用只读入口
    //
    // 内部可见性（不加 private），只为让 @testable 单测能驱动到 A1/A2 那两条回归路径，
    // 不构成对外 API——本类型本来就只有 App 自己这一个调用方。

    var openWindowCount: Int { windows.count }
    func windowExists(forKey key: String) -> Bool { windows[key] != nil }
    func isSameWindow(_ lhsKey: String, _ rhsKey: String) -> Bool { windows[lhsKey] === windows[rhsKey] }
    func key(forWindow window: NSWindow) -> String? { windows.first(where: { $0.value === window })?.key }

    // MARK: - Internal

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        window.setFrameAutosaveName("KeysMirror.MacroEditor")
        window.center()
        return window
    }

    /// 内部可见性：A1 回归测试需要在不驱动整棵 SwiftUI 树的前提下直接触发这条重绑路径。
    func rebind(from oldKey: String, to newKey: String, window: NSWindow, title: String) {
        guard oldKey != newKey, windows[oldKey] === window else { return }
        forget(oldKey)
        window.title = title
        observeClose(of: window, key: newKey)
        windows[newKey] = window
        if hiddenForRecording == oldKey { hiddenForRecording = newKey }
    }

    private func observeClose(of window: NSWindow, key: String) {
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            assumingMainActor { MacroEditorWindowController.shared.forget(key) }
        }
    }

    private func forget(_ key: String) {
        if let observer = closeObservers[key] {
            NotificationCenter.default.removeObserver(observer)
            closeObservers[key] = nil
        }
        windows[key] = nil
        if hiddenForRecording == key { hiddenForRecording = nil }
    }

    /// 内部可见性：测试要能验证「同一个 macro 算出同一个 key」。
    static func key(for macro: MacroAction) -> String { key(for: macro.id) }
    static func key(for macroId: UUID) -> String { "macro-\(macroId.uuidString)" }
    private static func draftKey() -> String { "draft-\(UUID().uuidString)" }
}
