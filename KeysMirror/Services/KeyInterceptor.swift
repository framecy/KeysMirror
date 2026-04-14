import AppKit
@preconcurrency import CoreGraphics

@MainActor
final class KeyInterceptor {
    static let shared = KeyInterceptor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let store = MappingStore.shared
    private let windowLocator = WindowLocator.shared
    private let clickSimulator = ClickSimulator.shared
    private let logger = AppLogger.shared

    var isEnabled: Bool {
        eventTap != nil && CGEvent.tapIsEnabled(tap: eventTap!)
    }

    private init() {}

    func start() -> Bool {
        if isEnabled { return true }
        
        // 先彻底清理旧状态，避免重建时出现残留资源
        _teardown()

        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.rightMouseDown.rawValue) |
                        (1 << CGEventType.otherMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.log("权限不足，拦截器创建失败", type: "ERROR")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        logger.log("拦截器已重置并启动")
        return true
    }

    func stop() {
        _teardown()
        logger.log("拦截器已关闭")
    }
    
    /// 内部清理：先禁用 tap，再移除 RunLoop source，最后置 nil
    private func _teardown() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // 核心匹配逻辑：不再依赖任何 Helper，直接现场比对
    private func processEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passRetained(event)
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier else {
            return Unmanaged.passRetained(event)
        }

        if bundleId.lowercased().contains("keysmirror") {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventModifiers = ModifierHelper.cleanModifiers(from: event.flags)

        // TRACE 日志：确认拦截器收到了事件
        logger.log("探测 [\(bundleId)] | 键: \(keyCode) | 模: \(eventModifiers)", type: "TRACE")

        guard let profile = store.enabledProfile(bundleIdentifier: bundleId) else {
            return Unmanaged.passRetained(event)
        }

        let matchingMapping = profile.mappings.first { mapping in
            switch (type, mapping.triggerType) {
            case (.keyDown, .keyboard):
                return mapping.keyCode == keyCode && mapping.modifiers == eventModifiers && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            case (.rightMouseDown, .mouseRight):
                return true
            case (.otherMouseDown, .mouseOther):
                let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
                return (mapping.mouseButtonNumber ?? -1) == buttonNumber
            default:
                return false
            }
        }

        if let mapping = matchingMapping {
            guard let windowFrame = windowLocator.focusedWindowFrame(for: bundleId) else {
                logger.log("匹配成功但无法读取 [\(bundleId)] 窗口位置", type: "ERROR")
                return Unmanaged.passRetained(event)
            }

            let clickPoint = CoordinateConverter.absolutePoint(relativeX: mapping.relativeX, relativeY: mapping.relativeY, in: windowFrame)
            logger.log("【执行动作】触发 [\(mapping.label)]: 点击 (\(Int(clickPoint.x)), \(Int(clickPoint.y)))", type: "ACTION")
            
            // 模拟点击
            clickSimulator.leftClick(at: clickPoint, targetApp: frontApp)
            
            // 根据 blockInput 决定是否拦截按键
            // 如果 blockInput = true，拦截按键不传递到游戏
            // 如果 blockInput = false，按键同时传递到游戏
            if mapping.blockInput {
                StatusBarController.shared.flashActivity()
                return nil  // 拦截按键
            } else {
                // 不拦截，按键同时传递到游戏
                return Unmanaged.passRetained(event)
            }
        }

        return Unmanaged.passRetained(event)
    }

    private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passRetained(event) }
        let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        let unsafeEvent = UnsafeEvent(value: event)
        return MainActor.assumeIsolated {
            interceptor.processEvent(type: type, event: unsafeEvent.value)
        }
    }
}

private struct UnsafeEvent: @unchecked Sendable {
    let value: CGEvent
}
