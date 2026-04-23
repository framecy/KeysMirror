import ApplicationServices
import AppKit

@MainActor
final class WindowLocator {
    static let shared = WindowLocator()

    /// 由 ActiveAppAXObserver 推送维护的"当前前台焦点是否在文字输入控件"状态。
    /// keyDown 命中时直接读取，不再触发 AX IPC。
    private struct FocusState {
        let bundleId: String
        let isTextInput: Bool
    }
    private var observedFocus: FocusState?

    /// 焦点窗口 frame 缓存。命中后零 AX IPC；窗口移动 / 缩放 / 切前台 app 时由
    /// `.focusedWindowFrameChanged` 广播失效，同步性靠 AXObserver 推送保证。
    private var cachedFrame: (bundleId: String, frame: CGRect)?

    /// 测试接缝：注入 frame 查询。生产路径走真正的 AX 调用；单测可注入桩。
    var frameProviderForTesting: ((String) -> CGRect?)?

    private init() {
        ActiveAppAXObserver.shared.onFocusedElementChanged = { [weak self] pid in
            self?.refreshFocusState(pid: pid)
        }
        NotificationCenter.default.addObserver(
            forName: .focusedWindowFrameChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cachedFrame = nil
            }
        }
    }

    func focusedWindowFrame(for bundleIdentifier: String) -> CGRect? {
        if let cache = cachedFrame, cache.bundleId == bundleIdentifier {
            return cache.frame
        }
        let query = frameProviderForTesting ?? { [weak self] bid in self?.queryFocusedWindowFrame(for: bid) }
        guard let frame = query(bundleIdentifier) else {
            return nil
        }
        cachedFrame = (bundleIdentifier, frame)
        return frame
    }

    /// 测试用：手动清空 frame 缓存
    func clearFrameCacheForTesting() {
        cachedFrame = nil
    }

    private func queryFocusedWindowFrame(for bundleIdentifier: String) -> CGRect? {
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

    /// 返回 true 表示目标应用当前焦点在文字输入控件上（应暂停键盘映射）。
    /// 优先读取 AXObserver 维护的缓存，缓存未命中（启动竞态 / observer 注册失败）时退化为现场查询。
    func isFocusedElementTextInput(for bundleIdentifier: String) -> Bool {
        if let state = observedFocus, state.bundleId == bundleIdentifier {
            return state.isTextInput
        }
        return queryFocusedTextInput(for: bundleIdentifier)
    }

    private func refreshFocusState(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleId = app.bundleIdentifier else {
            observedFocus = nil
            return
        }
        observedFocus = FocusState(
            bundleId: bundleId,
            isTextInput: queryFocusedTextInput(for: bundleId)
        )
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
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
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
