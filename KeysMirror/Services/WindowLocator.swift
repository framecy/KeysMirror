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

    // MARK: - 窗口尺寸可调性

    /// 一个目标窗口在「能不能改大小」上的实际情况。
    struct ResizeProbe {
        let appName: String
        /// 拿不到窗口对象时为 nil——这类目标的 AX 树不完整，改尺寸无从谈起。
        let currentSize: CGSize?
        /// AX 声明 `AXSize` 可写。声明可写不等于真能改，所以还有下面这个实测字段。
        let claimsSettable: Bool
        /// 真的改了一次再读回来，尺寸确实变了。这才是可信的结论。
        let actuallyResized: Bool
        /// 失败时的说明，直接写给用户看。
        let note: String
    }

    /// 实测目标窗口能否通过辅助功能 API 改大小，测完把尺寸复原。
    ///
    /// 为什么要「真的改一次」而不是只查 `AXUIElementIsAttributeSettable`：
    /// 「设计给 iPad」的 App Store 应用由系统的 iOS 兼容层托管窗口，它的 Info.plist 里
    /// `UIRequiresFullScreen = true` 就意味着窗口尺寸固定。AX 层完全可能报告「可写」，
    /// 而设置请求被兼容层默默忽略——只查声明会得出错误结论。
    ///
    /// 改完立刻复原：这是探测，不该留下副作用。
    func probeResizability(bundleIdentifier: String) -> ResizeProbe {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else {
            return ResizeProbe(appName: bundleIdentifier, currentSize: nil, claimsSettable: false,
                               actuallyResized: false, note: "没在运行")
        }
        let name = app.localizedName ?? bundleIdentifier
        let axApp = AXUtilities.makeAppElement(pid: app.processIdentifier)

        var windowsValue: CFTypeRef?
        let listResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)
        guard listResult == .success, let windows = windowsValue as? [AXUIElement], let window = windows.first else {
            return ResizeProbe(appName: name, currentSize: nil, claimsSettable: false, actuallyResized: false,
                               note: "拿不到窗口对象（AXWindows code=\(listResult.rawValue)）——AX 树不完整，这条路走不通")
        }

        guard let before = axSize(of: window) else {
            return ResizeProbe(appName: name, currentSize: nil, claimsSettable: false, actuallyResized: false,
                               note: "读不到 AXSize")
        }

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)

        // 缩到八成试一下。取八成是因为足够大到能看出变化，又不至于把窗口弄得没法用。
        var target = CGSize(width: (before.width * 0.8).rounded(), height: (before.height * 0.8).rounded())
        guard let value = AXValueCreate(.cgSize, &target) else {
            return ResizeProbe(appName: name, currentSize: before, claimsSettable: settable.boolValue,
                               actuallyResized: false, note: "构造 AXValue 失败")
        }
        let setResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        let after = axSize(of: window)
        let changed = after.map { abs($0.width - before.width) >= 1 } ?? false

        if changed, var restore = Optional(before), let restoreValue = AXValueCreate(.cgSize, &restore) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, restoreValue)
        }

        var note: String
        if changed {
            note = "可以改（\(Int(before.width))x\(Int(before.height)) → \(Int(target.width))x\(Int(target.height))，已复原）"
        } else {
            note = "设置请求返回 code=\(setResult.rawValue)，但尺寸没变——外部强塞尺寸这条路不通"
            // 强塞不行，再试「让应用自己改」：按窗口的 zoom 按钮。这两条是不同的路径——
            // AXSize 是外部指定几何，zoom 是请求应用切换到它自己认可的尺寸，
            // 被 UIRequiresFullScreen 锁住的窗口未必两条都堵。
            note += " || " + probeZoomButton(window) + " || " + probePositionMove(window)
            note += " || " + attributeInventory(of: window)
        }
        return ResizeProbe(appName: name, currentSize: before, claimsSettable: settable.boolValue,
                           actuallyResized: changed, note: note)
    }

    /// 按一次目标窗口的 zoom 按钮，返回一句可直接写进日志的说明。
    ///
    /// 这是目前**唯一被证实能改变「设计给 iPad」窗口尺寸**的手段：直接写 `AXSize` 会被
    /// 系统的 iOS 兼容层收下然后忽略，`AXPosition` 更是完全锁死，只有 zoom 这条
    /// 「请求应用自己换尺寸」的路走得通。
    ///
    /// 与 `probeZoomButton` 的区别：那个是探测（按完立刻按回去），这个是**执行一次**，
    /// 不复原——用来把窗口按到想要的档位，也用来摸清它在几个尺寸之间怎么循环。
    func pressZoomButton(bundleIdentifier: String) -> String {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) else { return "\(bundleIdentifier) 没在运行" }
        let name = app.localizedName ?? bundleIdentifier
        let axApp = AXUtilities.makeAppElement(pid: app.processIdentifier)

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement], let window = windows.first else {
            return "\(name): 拿不到窗口"
        }
        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXZoomButton" as CFString, &buttonValue) == .success,
              let buttonValue else { return "\(name): 没有 zoom 按钮" }

        let before = axSize(of: window)
        AXUIElementPerformAction(unsafeDowncast(buttonValue, to: AXUIElement.self), kAXPressAction as CFString)
        // 1.2s：窗口缩放有动画，之前用 600ms 读回来的还是旧值，误判成「按了没反应」。
        usleep(1_200_000)
        let after = axSize(of: window)

        func fmt(_ s: CGSize?) -> String { s.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?" }
        return "\(name): \(fmt(before)) → \(fmt(after))"
    }

    /// 按一次窗口的 zoom 按钮（绿灯的「缩放」行为），看尺寸有没有变；变了就按回去复原。
    ///
    /// 与直接写 `AXSize` 是两条不同的路：写 AXSize 是外部强塞一个几何尺寸，被系统的
    /// iOS 兼容层直接忽略；zoom 是**请求应用自己**切换到它认可的另一个尺寸。
    /// 「设计给 iPad」的窗口同时暴露了 AXZoomButton 与 AXFullScreenButton，说明这两件事
    /// 在它这儿是分开的，所以值得单独试。
    private func probeZoomButton(_ window: AXUIElement) -> String {
        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXZoomButton" as CFString, &buttonValue) == .success,
              let buttonValue else { return "zoom按钮: 没有" }
        let button = unsafeDowncast(buttonValue, to: AXUIElement.self)
        guard let before = axSize(of: window) else { return "zoom按钮: 读不到尺寸" }

        let pressResult = AXUIElementPerformAction(button, kAXPressAction as CFString)
        usleep(600_000)  // 给应用留出重新布局的时间
        guard let after = axSize(of: window) else { return "zoom按钮: 按后读不到尺寸" }

        let changed = abs(after.width - before.width) >= 1 || abs(after.height - before.height) >= 1
        guard changed else {
            return "zoom按钮: 按了(code=\(pressResult.rawValue))但尺寸没变"
        }
        // 变了就按回去——这是探测，不该改变用户的窗口状态
        AXUIElementPerformAction(button, kAXPressAction as CFString)
        usleep(600_000)
        let restored = axSize(of: window).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
        return "zoom按钮: ✅ 有效 \(Int(before.width))x\(Int(before.height)) → "
             + "\(Int(after.width))x\(Int(after.height))（已按回，现为 \(restored)）"
    }

    /// 实测窗口能不能挪位置。位置也挪不动就说明兼容层把窗口几何整个锁死了。
    private func probePositionMove(_ window: AXUIElement) -> String {
        var posValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              let posValue, CFGetTypeID(posValue) == AXValueGetTypeID() else { return "位置: 读不到" }
        var before = CGPoint.zero
        AXValueGetValue(unsafeDowncast(posValue, to: AXValue.self), .cgPoint, &before)

        var target = CGPoint(x: before.x + 40, y: before.y)
        guard let targetValue = AXValueCreate(.cgPoint, &target) else { return "位置: 构造失败" }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, targetValue)
        usleep(300_000)

        var afterValue: CFTypeRef?
        var after = CGPoint.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &afterValue) == .success,
           let afterValue, CFGetTypeID(afterValue) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(afterValue, to: AXValue.self), .cgPoint, &after)
        }
        let moved = abs(after.x - before.x) >= 1
        if moved, var restore = Optional(before), let restoreValue = AXValueCreate(.cgPoint, &restore) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, restoreValue)
        }
        return moved ? "位置: ✅ 能挪（已复原）" : "位置: ❌ 挪不动 —— 窗口几何被整个锁死"
    }

    /// 列出窗口暴露的全部 AX 属性及其可写性，另附可执行的 action（zoom / resize 按钮之类）。
    /// 尺寸改不动时用它回答「还有没有别的口子」。
    private func attributeInventory(of window: AXUIElement) -> String {
        var namesValue: CFArray?
        var parts: [String] = []

        if AXUIElementCopyAttributeNames(window, &namesValue) == .success,
           let names = namesValue as? [String] {
            let writable = names.filter { name in
                var settable: DarwinBoolean = false
                return AXUIElementIsAttributeSettable(window, name as CFString, &settable) == .success
                    && settable.boolValue
            }
            parts.append("属性(\(names.count))=[\(names.joined(separator: ","))]")
            parts.append("其中可写=[\(writable.isEmpty ? "无" : writable.joined(separator: ","))]")
        } else {
            parts.append("属性列表读不到")
        }

        var actionsValue: CFArray?
        if AXUIElementCopyActionNames(window, &actionsValue) == .success,
           let actions = actionsValue as? [String], !actions.isEmpty {
            parts.append("可执行动作=[\(actions.joined(separator: ","))]")
        }
        return parts.joined(separator: " | ")
    }

    private func axSize(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cgSize, &size)
        return size
    }
}
