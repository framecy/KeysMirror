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

    /// 用户侧"是否开启映射"意图（来自菜单栏 toggle / start()/stop()）
    private var userEnabled: Bool = false
    /// 当前前台 app 是否有启用的 profile（由 AppDelegate 监听前台切换推送）
    private var hasActiveProfile: Bool = true

    /// 用户可见的启用状态：反映用户意图而非 tap 是否正在工作。
    /// 智能暂停（hasActiveProfile=false）时菜单栏仍显示为"已启用"，避免误导。
    var isEnabled: Bool { userEnabled }

    private init() {}

    func start() -> Bool {
        userEnabled = true
        if eventTap != nil {
            applyTapState()
            return true
        }

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
        applyTapState()

        logger.log("拦截器已重置并启动")
        return true
    }

    func stop() {
        userEnabled = false
        _teardown()
        logger.log("拦截器已关闭")
    }

    /// AppDelegate 在前台 app 切换时调用：当前 app 无可用 profile 时，
    /// 暂停 tap 以避免每次全局按键的进程间唤醒成本（tap 本身不销毁，避免重建开销）。
    func setActiveProfileAvailable(_ available: Bool) {
        guard hasActiveProfile != available else { return }
        hasActiveProfile = available
        applyTapState()
    }

    private func applyTapState() {
        guard let tap = eventTap else { return }
        let shouldEnable = userEnabled && hasActiveProfile
        CGEvent.tapEnable(tap: tap, enable: shouldEnable)
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
    private func processEvent(type: CGEventType, event: CGEvent?) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 系统在此类型事件中传入 null event；不能 passRetained
            // 我们主动 disable 时（智能暂停 / stop()）系统也会送来 .tapDisabledByUserInput——
            // 仅当用户意图开启且当前 app 有 profile 时才尝试恢复，否则忽略避免死循环
            guard userEnabled && hasActiveProfile, let tap = eventTap else {
                return nil
            }
            logger.log("事件 tap 被系统禁用 (type=\(type.rawValue))，尝试恢复", type: "WARN")
            CGEvent.tapEnable(tap: tap, enable: true)
            return nil
        }

        guard let event else { return nil }

        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier else {
            return Unmanaged.passRetained(event)
        }

        if bundleId.lowercased().contains("keysmirror") {
            return Unmanaged.passRetained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let eventModifiers = ModifierHelper.cleanModifiers(from: event.flags)

        guard let profile = store.enabledProfile(bundleIdentifier: bundleId) else {
            return Unmanaged.passRetained(event)
        }

        // 文字输入焦点检测：仅对键盘事件生效，鼠标侧键映射不受影响
        if type == .keyDown && windowLocator.isFocusedElementTextInput(for: bundleId) {
            return Unmanaged.passRetained(event)
        }

        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))

        // 宏匹配优先：先看是否正好是当前运行宏的触发键（→ 停），再看 profile.macros 是否命中（→ 启动）
        if let runningId = MacroRunner.shared.runningMacroId,
           let runningMacro = profile.macros.first(where: { $0.id == runningId }),
           triggerMatches(event: event, type: type, keyCode: keyCode, eventModifiers: eventModifiers, buttonNumber: buttonNumber,
                          triggerType: runningMacro.triggerType, mappingKeyCode: runningMacro.keyCode,
                          mappingModifiers: runningMacro.modifiers, mappingButton: runningMacro.mouseButtonNumber) {
            MacroRunner.shared.stop(reason: "用户再按触发键")
            StatusBarController.shared.flashActivity()
            return runningMacro.blockInput ? nil : Unmanaged.passRetained(event)
        }

        if let macro = profile.macros.first(where: { macro in
            macro.isEnabled && triggerMatches(
                event: event, type: type, keyCode: keyCode, eventModifiers: eventModifiers, buttonNumber: buttonNumber,
                triggerType: macro.triggerType, mappingKeyCode: macro.keyCode,
                mappingModifiers: macro.modifiers, mappingButton: macro.mouseButtonNumber
            )
        }) {
            MacroRunner.shared.toggle(macro, profile: profile)
            return macro.blockInput ? nil : Unmanaged.passRetained(event)
        }

        let matchingMapping = profile.mappings.first { mapping in
            guard mapping.isEnabled else { return false }
            return triggerMatches(
                event: event, type: type, keyCode: keyCode, eventModifiers: eventModifiers, buttonNumber: buttonNumber,
                triggerType: mapping.triggerType, mappingKeyCode: mapping.keyCode,
                mappingModifiers: mapping.modifiers, mappingButton: mapping.mouseButtonNumber
            )
        }

        if let mapping = matchingMapping {
            guard let windowFrame = windowLocator.focusedWindowFrame(for: bundleId) else {
                logger.log("匹配成功但无法读取 [\(bundleId)] 窗口位置", type: "ERROR")
                return Unmanaged.passRetained(event)
            }

            let offset = mapping.absoluteOffset(in: windowFrame.size)
            let clickPoint = CoordinateConverter.absolutePoint(relativeX: offset.x, relativeY: offset.y, in: windowFrame)

            // 详细动作日志：暴露缩放跟随的实际状态，便于用户自查"点击位置不准"问题
            let winW = Int(windowFrame.width)
            let winH = Int(windowFrame.height)
            let relX = Int(mapping.relativeX)
            let relY = Int(mapping.relativeY)
            let cx = Int(clickPoint.x)
            let cy = Int(clickPoint.y)
            if let refW = mapping.referenceWidth, let refH = mapping.referenceHeight, refW > 0, refH > 0 {
                let sx = windowFrame.width / refW
                let sy = windowFrame.height / refH
                logger.log("【执行动作】[\(mapping.label)] 偏移(\(relX),\(relY)) × \(String(format: "%.2f", sx))/\(String(format: "%.2f", sy)) | 窗口 \(winW)x\(winH) | 参考 \(Int(refW))x\(Int(refH)) → 点击 (\(cx),\(cy))", type: "ACTION")
            } else {
                logger.log("【执行动作】[\(mapping.label)] 偏移(\(relX),\(relY)) | 窗口 \(winW)x\(winH) | ⚠️ 无参考尺寸（v1.2 旧映射不支持缩放跟随，请编辑→重录位置） → 点击 (\(cx),\(cy))", type: "ACTION")
            }

            // 安全网：若缺参考且当前窗口已被缩小到使点击点落在窗口外，拒绝点击避免唤醒后面的 app
            if !mapping.hasScaleReference,
               !windowFrame.contains(clickPoint) {
                logger.log("点击点 (\(cx),\(cy)) 落在窗口 \(winW)x\(winH) 外，已拒绝以免误触后台应用——请重录此映射启用缩放跟随", type: "WARN")
                return mapping.blockInput ? nil : Unmanaged.passRetained(event)
            }
            
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

    /// 统一的触发匹配：mappings 与 macros 共用同一份 (event, type) ↔ (triggerType, ...) 比对逻辑。
    private func triggerMatches(
        event: CGEvent,
        type: CGEventType,
        keyCode: UInt16,
        eventModifiers: UInt64,
        buttonNumber: Int,
        triggerType: TriggerType,
        mappingKeyCode: UInt16,
        mappingModifiers: UInt64,
        mappingButton: Int?
    ) -> Bool {
        switch (type, triggerType) {
        case (.keyDown, .keyboard):
            return mappingKeyCode == keyCode
                && mappingModifiers == eventModifiers
                && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        case (.rightMouseDown, .mouseRight):
            return true
        case (.otherMouseDown, .mouseOther):
            return (mappingButton ?? -1) == buttonNumber
        default:
            return false
        }
    }

    private nonisolated static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passRetained(event) }
        let interceptor = Unmanaged<KeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        // tapDisabledByTimeout / tapDisabledByUserInput 时底层 C 指针为 null，
        // Swift 仍将其包装成非 Optional，手动转为 nil 避免使用悬空指针
        let optionalEvent: CGEvent? = (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput) ? nil : event
        let unsafeEvent = UnsafeOptionalEvent(value: optionalEvent)
        return MainActor.assumeIsolated {
            interceptor.processEvent(type: type, event: unsafeEvent.value)
        }
    }
}

private struct UnsafeOptionalEvent: @unchecked Sendable {
    let value: CGEvent?
}
