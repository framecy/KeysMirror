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
        let timestamp: TimeInterval
    }
    private var observedFocus: FocusState?

    /// frame 是从哪条路径拿到的。决定缓存能存多久（见 `cacheTTL(for:)`）。
    enum FrameSource {
        /// 目标 app 的 Accessibility 正常应答。窗口移动 / 缩放会由 AXObserver 推送失效缓存。
        case accessibility
        /// AX 不可用，退回 Window Server 的窗口列表。没有任何推送可依赖。
        case windowList
    }

    struct ResolvedFrame {
        let frame: CGRect
        let source: FrameSource
    }

    /// 焦点窗口 frame 缓存。命中后零 AX IPC；窗口移动 / 缩放 / 切前台 app 时由
    /// `.focusedWindowFrameChanged` 广播失效，同步性靠 AXObserver 推送保证。
    private struct FrameCacheEntry {
        let bundleId: String
        let frame: CGRect
        let source: FrameSource
        let timestamp: TimeInterval
    }
    private var cachedFrame: FrameCacheEntry?

    /// 已经为哪些 app 记过「已降级到 CGWindowList」日志，避免每次按键刷屏。
    private var windowListFallbackLogged: Set<String> = []

    /// 小于这个边长的窗口不当主窗口。输入法候选框、提示气泡都在这个量级以下。
    private static let minimumUsableWindowSide: CGFloat = 120

    /// 兜底 TTL：部分 app（iOS-on-Mac / 自绘 Metal 游戏）AX 通知注册成功但实际不推送，
    /// 缓存可能永久卡死——focus 卡在 isTextInput=true 让所有 keyDown 直通；frame 卡在
    /// 旧值让点击落到窗口外被安全网拒绝。TTL 限制 stale 时长，到期后 keyDown 路径自费
    /// 一次 AX IPC 重新探测并刷新缓存，正常 app 走 observer 推送几乎不进 TTL 分支。
    ///
    /// 注意：AX 查询在主线程同步执行，TTL 太短会导致每隔几秒就阻塞主线程，
    /// 期间鼠标光标无法响应，用户体验为「鼠标失灵」。
    /// - focusCacheTTL：15s，覆盖 silent observer 的 isTextInput 卡住场景，频率可接受
    /// - frameCacheTTL：60s，游戏窗口几乎不移动，observer 推送会提前失效缓存
    /// - windowListFrameCacheTTL：1s，这条路径没有 observer 可依赖，但也不进目标进程，刷得起
    private static let focusCacheTTL: TimeInterval = 15.0
    private static let frameCacheTTL: TimeInterval = 60.0
    private static let windowListFrameCacheTTL: TimeInterval = 1.0

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
        let now = Date.timeIntervalSinceReferenceDate
        if let cache = cachedFrame,
           cache.bundleId == bundleIdentifier,
           now - cache.timestamp < Self.cacheTTL(for: cache.source) {
            return cache.frame
        }
        guard let resolved = resolveFrame(for: bundleIdentifier) else {
            return nil
        }
        cachedFrame = FrameCacheEntry(
            bundleId: bundleIdentifier,
            frame: resolved.frame,
            source: resolved.source,
            timestamp: now
        )
        return resolved.frame
    }

    private func resolveFrame(for bundleIdentifier: String) -> ResolvedFrame? {
        if let stub = frameProviderForTesting {
            return stub(bundleIdentifier).map { ResolvedFrame(frame: $0, source: .accessibility) }
        }
        return queryFocusedWindowFrame(for: bundleIdentifier)
    }

    /// AX 路径有 AXObserver 推送兜着，可以缓存很久；CGWindowList 路径没有任何失效信号，
    /// 只能靠短 TTL 保鲜。好在后者不进目标进程（Window Server 直接应答），刷勤一点也不心疼。
    private static func cacheTTL(for source: FrameSource) -> TimeInterval {
        switch source {
        case .accessibility: return frameCacheTTL
        case .windowList: return windowListFrameCacheTTL
        }
    }

    /// 测试用：手动清空 frame 缓存
    func clearFrameCacheForTesting() {
        cachedFrame = nil
    }

    /// 查询目标 app 的焦点窗口 frame。
    ///
    /// 三级降级，任何一级拿到**有效** frame 就返回：
    ///   1. AX `kAXFocusedWindowAttribute` —— 正常 app 走这条；
    ///   2. AX `kAXWindowsAttribute` 里第一个能读出几何的窗口 —— app 不报告焦点窗口时兜底；
    ///   3. Window Server 窗口列表（`CGWindowListCopyWindowInfo`）—— AX 整条链都不应答时兜底。
    ///
    /// 第 3 级是给「AX 形同虚设」的 app 准备的：部分 iOS-on-Mac / 自绘游戏要么整个 AX 树不应答，
    /// 要么给得出 AXFocusedWindow 却读不到它的 AXPosition/AXSize。以前这里直接返回 nil，
    /// KeyInterceptor 只能记一行「匹配成功但无法读取窗口位置」然后放行原始按键——
    /// 用户体感就是这个游戏里快捷键完全失灵（其它 app 一切正常）。
    /// CGWindowList 由 Window Server 直接应答、不进目标进程，不受目标 app 的 AX 实现好坏影响。
    ///
    /// 注意第 1 级失败**不能**直接 return nil：拿到了 AXFocusedWindow 但读不出几何属性时必须继续往下走，
    /// 否则第 2、3 级永远没机会执行——这正是旧实现的漏洞。
    private func queryFocusedWindowFrame(for bundleIdentifier: String) -> ResolvedFrame? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }
        let pid = app.processIdentifier
        let applicationElement = AXUtilities.makeAppElement(pid: pid)

        var focusedWindowValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue)
        if focusedResult == .success,
           let focusedWindowValue,
           let frame = frame(for: focusedWindowValue) {
            return ResolvedFrame(frame: frame, source: .accessibility)
        }

        var windowsValue: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &windowsValue)
        if windowsResult == .success,
           let windows = windowsValue as? [AXUIElement],
           let frame = windows.lazy.compactMap({ self.frame(for: $0) }).first {
            return ResolvedFrame(frame: frame, source: .accessibility)
        }

        if let frame = Self.queryWindowListFrame(ownedBy: pid) {
            noteWindowListFallback(for: bundleIdentifier)
            return ResolvedFrame(frame: frame, source: .windowList)
        }

        return nil
    }

    /// 用 Window Server 的窗口列表取 pid 的主窗口 frame。
    ///
    /// `kCGWindowBounds` 与 AX 用的是同一套坐标系（主屏左上角为原点、Y 向下），可以直接当 AX frame 用——
    /// `occludingApp(at:ownedBy:)` 早就在混用这两者做命中判断了。
    /// 只查 `.optionOnScreenOnly`，所以最小化 / 隐藏的窗口自然选不中，与 AX 路径拒绝最小化窗口的行为一致。
    private static func queryWindowListFrame(ownedBy pid: pid_t) -> CGRect? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return mainWindowFrame(fromWindowList: infos, ownedBy: pid)
    }

    /// 从窗口列表快照里挑出 pid 的主窗口。抽成纯函数是为了能直接喂假数据做单测。
    ///
    /// 取「面积最大」而不是「最靠前」：游戏进程常常还挂着输入法候选框、提示气泡这类 layer 0 的小窗口，
    /// 它们可能排在主窗口前面。面积最大的那个才是要点击的游戏画面。
    static func mainWindowFrame(fromWindowList infos: [[String: Any]], ownedBy pid: pid_t) -> CGRect? {
        var best: CGRect?
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            guard bounds.width >= minimumUsableWindowSide,
                  bounds.height >= minimumUsableWindowSide else { continue }
            if let current = best, current.width * current.height >= bounds.width * bounds.height { continue }
            best = bounds
        }
        return best
    }

    /// 第一次对某个 app 用上 CGWindowList 兜底时记一行日志。
    /// 每次按键都记会把日志刷爆，完全不记的话用户排查「这个游戏怎么和别的不一样」时又没线索。
    private func noteWindowListFallback(for bundleIdentifier: String) {
        guard windowListFallbackLogged.insert(bundleIdentifier).inserted else { return }
        AppLogger.shared.log(
            "[\(bundleIdentifier)] AX 读不到窗口位置，改用 Window Server 窗口列表兜底（该 app 的 AX 实现不完整，属预期降级）",
            type: "WARN"
        )
    }

    func relativePoint(from screenPoint: CGPoint, inWindowFrame windowFrame: CGRect) -> CGPoint? {
        CoordinateConverter.relativePoint(from: screenPoint, in: windowFrame)
    }

    /// `point` 处最上层的普通窗口是否属于 pid 指定的进程。
    ///
    /// 宏在非前台执行时，点击走的仍是 session 层——事件由 Window Server 按「光标位置下的窗口」
    /// 路由。平铺布局本身不重叠，但用户随时可能把别的窗口拖到游戏上面，那时点击就会打进
    /// 那个窗口（可能是浏览器的发送、编辑器的删除按钮）。每次点击前先确认目标真的露在最上层。
    ///
    /// 用 CGWindowList 而不是 AX 命中测试：AX 要与目标进程同步 IPC 并阻塞主线程，
    /// 宏反复调用会让用户的鼠标发卡——而「不影响鼠标操作」正是后台跑宏的前提。
    /// CGWindowList 由 Window Server 直接返回，不进目标进程。
    /// - Returns: nil 表示目标窗口在该点可见；否则返回挡在上面的窗口所属 app 名，供日志指名道姓。
    func occludingApp(at point: CGPoint, ownedBy pid: pid_t) -> String? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil   // 拿不到窗口列表时不阻拦，避免误杀整个宏
        }

        // KeysMirror 自己的浮层（HUD / 录制高亮 / 位置遮罩）都是 ignoresMouseEvents，
        // 点击会穿透过去，不构成真实遮挡。它们的 level 通常是 .statusBar（layer≠0）已被下面
        // 的 layer 过滤挡掉，这里再按窗口号精确排除一次，避免将来有人改了 level 就出错。
        let clickThrough = Set(NSApp.windows.filter { $0.ignoresMouseEvents }.map { $0.windowNumber })

        // 返回顺序即前后顺序（靠前 = 更上层）。取第一个命中的普通窗口即可判定遮挡。
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
               clickThrough.contains(number) { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            guard bounds.contains(point) else { continue }

            if (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid { return nil }
            return (info[kCGWindowOwnerName as String] as? String) ?? "未知窗口"
        }
        // 该点没有任何普通窗口——目标窗口可能已最小化 / 移走，按遮挡处理更安全
        return "无窗口命中"
    }

    /// 让 frame 缓存立即失效。
    /// 问道这类 app 的 AX 通知注册成功却从不推送（日志可见 code=-25211），窗口被移动 / 缩放时
    /// 缓存不会被动失效，只能靠 TTL 兜底——后台跑宏时这最长 60s 的陈旧期会让点击系统性偏移。
    func invalidateFrameCache() {
        cachedFrame = nil
    }

    func frameContainingPoint(_ screenPoint: CGPoint, for bundleIdentifier: String) -> CGRect? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return nil
        }

        let axPoint = CoordinateConverter.appKitScreenPointToAX(screenPoint)
        let systemWideElement = AXUtilities.makeSystemWideElement()
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

        let applicationElement = AXUtilities.makeAppElement(pid: app.processIdentifier)
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
        let window = unsafeDowncast(windowValue, to: AXUIElement.self)
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
        AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &origin)
        AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func unpackWindows(from value: CFTypeRef) -> [AXUIElement] {
        let array = unsafeDowncast(value, to: CFArray.self)
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
            return unsafeDowncast(windowValue, to: AXUIElement.self)
        }

        var topLevelValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTopLevelUIElementAttribute as CFString, &topLevelValue) == .success,
           let topLevelValue,
           CFGetTypeID(topLevelValue) == AXUIElementGetTypeID() {
            return unsafeDowncast(topLevelValue, to: AXUIElement.self)
        }

        return nil
    }

    /// 返回 true 表示目标应用当前焦点在文字输入控件上（应暂停键盘映射）。
    /// 优先读取 AXObserver 维护的缓存；缓存未命中或超过 TTL 时现场查询并写回缓存——
    /// 后者覆盖「observer 注册成功但不推送」的 app 让缓存永久卡 true 的情况。
    func isFocusedElementTextInput(for bundleIdentifier: String) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        if let state = observedFocus,
           state.bundleId == bundleIdentifier,
           now - state.timestamp < Self.focusCacheTTL {
            return state.isTextInput
        }
        let fresh = queryFocusedTextInput(for: bundleIdentifier)
        observedFocus = FocusState(bundleId: bundleIdentifier, isTextInput: fresh, timestamp: now)
        return fresh
    }

    private func refreshFocusState(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bundleId = app.bundleIdentifier else {
            observedFocus = nil
            return
        }
        observedFocus = FocusState(
            bundleId: bundleId,
            isTextInput: queryFocusedTextInput(for: bundleId),
            timestamp: Date.timeIntervalSinceReferenceDate
        )
    }

    private func queryFocusedTextInput(for bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return false
        }
        let appElement = AXUtilities.makeAppElement(pid: app.processIdentifier)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedElement = unsafeDowncast(focusedValue, to: AXUIElement.self)

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
