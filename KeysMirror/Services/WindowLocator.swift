import ApplicationServices
import AppKit
import QuartzCore

@MainActor
final class WindowLocator {
    static let shared = WindowLocator()

    /// 焦点元素查询缓存：每个 keyDown 事件都做 AX IPC 太重，
    /// 在 50ms 窗口内复用上次结果，覆盖快速连按场景；正常切焦点几乎不会落进同一个 50ms 窗口。
    private struct FocusCache {
        let bundleId: String
        let timestamp: CFTimeInterval
        let isTextInput: Bool
    }
    private var focusCache: FocusCache?
    private let focusCacheTTL: CFTimeInterval = 0.05

    private init() {}

    func focusedWindowFrame(for bundleIdentifier: String) -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindowValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        if focusedResult == .success, let focusedWindowValue {
            return frame(for: focusedWindowValue)
        }

        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue)
        if windowsResult == .success,
           let windows = windowsValue as? [AXUIElement],
           let firstWindow = windows.first {
            return frame(for: firstWindow)
        }

        return nil
    }

    func relativePoint(from screenPoint: CGPoint, inWindowFrame windowFrame: CGRect) -> CGPoint? {
        CoordinateConverter.relativePoint(from: screenPoint, in: windowFrame)
    }

    func frameContainingPoint(_ screenPoint: CGPoint, for bundleIdentifier: String) -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }

        let axPoint = CoordinateConverter.appKitScreenPointToAX(screenPoint)
        let systemWideElement = AXUIElementCreateSystemWide()
        var elementAtPoint: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(systemWideElement, Float(axPoint.x), Float(axPoint.y), &elementAtPoint)

        if hitResult == .success,
           let elementAtPoint,
           let hitPID = pid(for: elementAtPoint),
           hitPID == app.processIdentifier,
           let window = topLevelWindow(for: elementAtPoint),
           let frame = frame(for: window),
           frame.contains(axPoint) {
            return frame
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue)

        guard windowsResult == .success, let windowsValue else {
            return focusedWindowFrame(for: bundleIdentifier)
        }

        let windows = unpackWindows(from: windowsValue)
        if let containingFrame = windows
            .compactMap({ frame(for: $0) })
            .first(where: { $0.contains(axPoint) }) {
            return containingFrame
        }

        return focusedWindowFrame(for: bundleIdentifier)
    }

    private func frame(for windowValue: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(windowValue, to: AXUIElement.self)
        return frame(for: window)
    }

    private func frame(for window: AXUIElement) -> CGRect? {
        var minimizedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
           let minimizedValue = minimizedValue as? Bool,
           minimizedValue {
            return nil
        }

        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)

        guard positionResult == .success, sizeResult == .success else { return nil }
        guard
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func unpackWindows(from value: CFTypeRef) -> [AXUIElement] {
        let array = unsafeBitCast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        var windows: [AXUIElement] = []
        windows.reserveCapacity(count)

        for index in 0..<count {
            let rawValue = CFArrayGetValueAtIndex(array, index)
            let window = unsafeBitCast(rawValue, to: AXUIElement.self)
            windows.append(window)
        }

        return windows
    }

    private func topLevelWindow(for element: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowValue) == .success,
           let windowValue,
           CFGetTypeID(windowValue) == AXUIElementGetTypeID() {
            return unsafeBitCast(windowValue, to: AXUIElement.self)
        }

        var topLevelValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTopLevelUIElementAttribute as CFString, &topLevelValue) == .success,
           let topLevelValue,
           CFGetTypeID(topLevelValue) == AXUIElementGetTypeID() {
            return unsafeBitCast(topLevelValue, to: AXUIElement.self)
        }

        return nil
    }

    /// 返回 true 表示目标应用当前焦点在文字输入控件上（应暂停键盘映射）
    func isFocusedElementTextInput(for bundleIdentifier: String) -> Bool {
        let now = CACurrentMediaTime()
        if let cache = focusCache,
           cache.bundleId == bundleIdentifier,
           now - cache.timestamp < focusCacheTTL {
            return cache.isTextInput
        }

        let result = queryFocusedTextInput(for: bundleIdentifier)
        focusCache = FocusCache(bundleId: bundleIdentifier, timestamp: now, isTextInput: result)
        return result
    }

    private func queryFocusedTextInput(for bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            return false
        }

        // 仅匹配真正的文字输入控件
        // 注意：不包含 AXWebArea——iOS-on-Mac 游戏的整个渲染面暴露为 AXWebArea，
        //       加入会导致游戏内所有映射失效
        let textInputRoles: Set<String> = [
            kAXTextFieldRole as String,   // 单行文本框
            kAXTextAreaRole as String,    // 多行文本框
            kAXComboBoxRole as String,    // 下拉组合框
            "AXSearchField",              // 搜索框（kAXSearchFieldRole 在部分 SDK 下不可用）
        ]
        return textInputRoles.contains(role)
    }

    private func pid(for element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            return nil
        }
        return pid
    }
}
