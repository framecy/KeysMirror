import AppKit
import SwiftUI

/// 窗口级撤销。
///
/// 本 App 是 `LSUIElement` 菜单栏程序，没有应用主菜单，`⌘Z` 不会经由
/// 「编辑 ▸ 撤销」菜单项走到响应链，所以这里自己装一个**局部**事件监听：
/// - 只在配置窗口是 key window 时生效；
/// - 第一响应者是文本编辑控件时**放行**，让输入框保留自己的打字撤销。
///
/// 所有会改动 `MappingStore` 的破坏性操作都应通过 `perform(name:do:undo:)` 执行，
/// 这样 `⌘Z` 与 Toast 上的「撤销」走的是同一条路径，不会出现「点了 Toast 撤销、
/// 再按 ⌘Z 又把东西加回来一次」的重复恢复。
@MainActor
final class UndoCoordinator: ObservableObject {
    static let shared = UndoCoordinator()

    let manager = UndoManager()

    /// 供 UI 显示「撤销 删除映射」用
    @Published private(set) var undoActionName: String?
    @Published private(set) var redoActionName: String?

    private var monitor: Any?

    private init() {
        manager.groupsByEvent = false
        manager.levelsOfUndo = 50
    }

    var canUndo: Bool { manager.canUndo }
    var canRedo: Bool { manager.canRedo }

    // MARK: - 注册与执行

    /// 执行一次可撤销操作：立即跑 `action`，并把 `undo` 压栈（撤销后自动登记重做）。
    ///
    /// `owner` 决定这条记录归谁：默认挂在协调器上（全局有效）；
    /// 传入某个短命对象（例如 Inspector 的 view model）后，可用
    /// `removeActions(for:)` 在它消失时把相关记录一并清掉，避免撤销到一个已经不在屏幕上的编辑器。
    func perform(
        name: String,
        owner: AnyObject? = nil,
        do action: @escaping () -> Void,
        undo: @escaping () -> Void
    ) {
        // 新操作发生 → 之前那条 Toast 上的「撤销」已经过期，先收掉，避免撤错东西
        ToastCenter.shared.dismiss()
        action()
        registerPair(name: name, owner: owner ?? self, forward: action, backward: undo)
        refreshNames()
    }

    /// 登记一条**已经发生**的变更（不重复执行）。
    /// 用于把连续输入合并成一条记录：改完一阵子之后，把「改动前 → 改动后」整体压栈。
    func registerPerformed(
        name: String,
        owner: AnyObject? = nil,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void
    ) {
        ToastCenter.shared.dismiss()
        registerPair(name: name, owner: owner ?? self, forward: redo, backward: undo)
        refreshNames()
    }

    /// 清掉某个对象名下的撤销记录（Inspector 关闭 / 切换选中项时调用）
    func removeActions(for owner: AnyObject) {
        manager.removeAllActions(withTarget: owner)
        refreshNames()
    }

    /// 撤销 / 重做（`⌘Z` / `⌘⇧Z` 与 Toast 按钮共用）
    func undo() {
        guard manager.canUndo else { return }
        manager.undo()
        refreshNames()
    }

    func redo() {
        guard manager.canRedo else { return }
        manager.redo()
        refreshNames()
    }

    func reset() {
        manager.removeAllActions()
        refreshNames()
    }

    /// 撤销后把「反向操作」再登记回去，于是 redo 可用；如此往复。
    ///
    /// `groupsByEvent = false`（不按 run loop 事件自动分组，行为更可预期、也让单测不依赖
    /// run loop）时，每次登记都必须显式开一个 group，否则 UndoManager 会报
    /// "must begin a group before registering undo"。
    private func registerPair(
        name: String,
        owner: AnyObject,
        forward: @escaping () -> Void,
        backward: @escaping () -> Void
    ) {
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: owner) { [owner] _ in
            assumingMainActor {
                backward()
                // 这一步跑在 undo 过程中，登记的是「重做」，同样需要自己的 group
                UndoCoordinator.shared.registerPair(name: name, owner: owner, forward: backward, backward: forward)
                UndoCoordinator.shared.refreshNames()
            }
        }
        manager.setActionName(name)
        manager.endUndoGrouping()
    }

    private func refreshNames() {
        undoActionName = manager.canUndo ? manager.undoActionName : nil
        redoActionName = manager.canRedo ? manager.redoActionName : nil
    }

    // MARK: - ⌘Z 键盘监听

    /// 配置窗口出现时装监听，消失时拆掉。
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // NSEvent 不是 Sendable，但监听回调只在主线程触发；
            // 与 PointRecorder / TriggerRecorder 里对 CGEvent 的处理同一思路。
            let boxed = UnsafeEventBox(event: event)
            // 只把「是否已消费」这个 Bool 传出来，事件本身留在闭包里。
            // （原因是当年 assumeIsolated 的返回值要求 Sendable；现在换成了
            //  assumingMainActor，没这个约束了，但保持现状——事件不外泄本身就是好的。）
            let consumed = assumingMainActor {
                UndoCoordinator.shared.handle(event: boxed.event)
            }
            return consumed ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// 返回 true 表示事件已被消费（不再下发）。
    private func handle(event: NSEvent) -> Bool {
        guard Self.isUndoShortcut(modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) else {
            return false
        }
        // 正在输入框里打字 → 让文本控件自己的撤销生效
        if let responder = event.window?.firstResponder, responder is NSText || responder is NSTextView {
            return false
        }
        if event.modifierFlags.contains(.shift) {
            redo()
        } else {
            undo()
        }
        return true
    }

    /// 纯函数，便于单测：是否是 ⌘Z / ⌘⇧Z（且不带 ⌥ / ⌃，避免误吞其他组合）
    static func isUndoShortcut(modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        guard let characters, characters.lowercased() == "z" else { return false }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        return flags.subtracting([.command, .shift]).isEmpty
    }
}

/// 把非 Sendable 的 NSEvent 搬过 @Sendable 闭包边界；仅主线程访问。
private struct UnsafeEventBox: @unchecked Sendable {
    let event: NSEvent
}
