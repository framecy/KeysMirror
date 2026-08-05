import AppKit
import Carbon.HIToolbox

/// 注册全局快捷键，触发时调用对应的回调。
/// 使用 Carbon RegisterEventHotKey（仍然是当前最稳的全局热键 API，
/// 不需要辅助功能权限以外的额外授权）。
///
/// v1.6 起支持**多个**热键（按 slot 区分）：
/// - `.toggleMappings`：全局启用 / 禁用映射
/// - `.cycleHUD`：游戏内 HUD 完整 / 紧凑 / 隐藏三态循环
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    /// 热键槽位。rawValue 直接作为 Carbon 的 hotKeyID.id，必须唯一且非 0。
    enum Slot: UInt32, CaseIterable {
        case toggleMappings = 1
        case cycleHUD = 2
    }

    /// 兼容旧调用点：等价于 `handler(for: .toggleMappings)`
    var onTrigger: (() -> Void)? {
        get { handlers[.toggleMappings] }
        set { handlers[.toggleMappings] = newValue }
    }

    private var handlers: [Slot: () -> Void] = [:]
    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = {
        // 'KMTG' (KeysMirror Toggle)
        let chars = Array("KMTG".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    private init() {}

    func setHandler(_ handler: @escaping () -> Void, for slot: Slot) {
        handlers[slot] = handler
    }

    /// 注册指定 slot 的 hotkey；先反注册再绑定，避免重复 handler。
    @discardableResult
    func register(_ config: HotkeyConfig, for slot: Slot = .toggleMappings) -> Bool {
        unregister(slot)
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            cgModifiersToCarbon(config.modifiers),
            EventHotKeyID(signature: Self.signature, id: slot.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            AppLogger.shared.log("RegisterEventHotKey 失败 (slot=\(slot), status=\(status))，全局热键未生效", type: "WARN")
            return false
        }
        hotKeyRefs[slot] = ref
        AppLogger.shared.log("全局热键已注册 [\(slot)]: \(CGKeyCodeNames.shortcutLabel(for: config.keyCode, modifiers: config.modifiers))")
        return true
    }

    func unregister(_ slot: Slot = .toggleMappings) {
        if let ref = hotKeyRefs[slot] {
            UnregisterEventHotKey(ref)
            hotKeyRefs.removeValue(forKey: slot)
        }
    }

    func unregisterAll() {
        for slot in Slot.allCases { unregister(slot) }
    }

    /// 完整拆除：反注册所有热键并卸载 Carbon event handler。
    /// 仅退出时调用——临时关闭热键功能用 `unregister()`，handler 留着复用更省。
    func teardown() {
        unregisterAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handlerProc,
            1,
            &spec,
            userData,
            &eventHandler
        )
        if status != noErr {
            AppLogger.shared.log("InstallEventHandler 失败 (status=\(status))", type: "WARN")
        }
    }

    private static let handlerProc: EventHandlerUPP = { _, eventRef, userData in
        guard let userData, let eventRef else { return noErr }
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr,
              receivedID.signature == GlobalHotkeyManager.signature,
              let slot = Slot(rawValue: receivedID.id) else {
            return noErr
        }
        let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            mgr.handlers[slot]?()
        }
        return noErr
    }

    /// CG 风格 modifier 位（KeyMapping.modifiers 用的）→ Carbon 风格
    private func cgModifiersToCarbon(_ flags: UInt64) -> UInt32 {
        let cg = CGEventFlags(rawValue: flags)
        var carbon: UInt32 = 0
        if cg.contains(.maskCommand)   { carbon |= UInt32(cmdKey) }
        if cg.contains(.maskShift)     { carbon |= UInt32(shiftKey) }
        if cg.contains(.maskControl)   { carbon |= UInt32(controlKey) }
        if cg.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
        return carbon
    }
}
