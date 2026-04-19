import AppKit
import Carbon.HIToolbox

/// 注册一个全局快捷键，触发时调用 `onTrigger`。
/// 使用 Carbon RegisterEventHotKey（仍然是当前最稳的全局热键 API，
/// 不需要辅助功能权限以外的额外授权）。
@MainActor
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = {
        // 'KMTG' (KeysMirror Toggle)
        let chars = Array("KMTG".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()
    private static let hotKeyID = EventHotKeyID(signature: GlobalHotkeyManager.signature, id: 1)

    private init() {}

    /// 注册指定 hotkey；先反注册再绑定，避免重复 handler。
    func register(_ config: HotkeyConfig) -> Bool {
        unregister()

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            cgModifiersToCarbon(config.modifiers),
            Self.hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            AppLogger.shared.log("RegisterEventHotKey 失败 (status=\(status))，全局热键未生效", type: "WARN")
            return false
        }
        hotKeyRef = ref
        AppLogger.shared.log("全局热键已注册: \(CGKeyCodeNames.shortcutLabel(for: config.keyCode, modifiers: config.modifiers))")
        return true
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
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
        guard status == noErr, receivedID.signature == GlobalHotkeyManager.signature else {
            return noErr
        }
        let mgr = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async {
            mgr.onTrigger?()
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
