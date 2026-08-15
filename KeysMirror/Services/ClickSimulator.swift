import CoreGraphics
import Foundation
import AppKit

@MainActor
final class ClickSimulator {
    static let shared = ClickSimulator()

    // 按 bundleId 缓存 iOS-on-Mac 判定结果。首次判定需要读盘 (Info.plist)，
    // 后续同一 bundleId 的点击零 I/O。App 退出时对应项失效，避免升级/重装后过期。
    private var nativeCache: [String: Bool] = [:]

    // CGEventSource 在整个生命周期内复用，省去每次点击的对象构造开销，
    // 同时 localEventsSuppressionInterval=0 只设一次，行为更稳定。
    private lazy var eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// 投递期间临时屏蔽**物理鼠标**事件的事件源，仅用于后台跑宏。
    ///
    /// 为什么需要：iOS-on-Mac 运行时靠鼠标移动事件流维护指针位置。宏在后台点击时，
    /// 用户正拿着鼠标在别的 app 里操作——一条真实的 mouseMoved 挤在我们的
    /// `moved(目标)` 和 `down` 之间，就会把游戏内部记的指针带走，这一击直接落空。
    /// disassociate 只冻结光标，拦不住硬件事件本身，必须靠这里的抑制区间。
    ///
    /// 只放行键盘与系统事件：用户在浏览器里打字不受影响，代价是每次点击前后各约
    /// `suppressionInterval` 的鼠标输入被吞掉。宏步之间通常隔着数百毫秒到数十秒，
    /// 这点损失基本无感。
    ///
    /// **不能**给前台映射点击用同一个源：映射触发频率高（每次按键一发），
    /// 那样会让玩家在游戏里的鼠标瞄准每按一次键就顿一下。
    private lazy var suppressingEventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = Self.clickDwell + 0.02
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return source
    }()

    // 测试接缝：注入 Info.plist 读取与 App 枚举逻辑
    var infoPlistProvider: (URL) -> NSDictionary? = { NSDictionary(contentsOf: $0) }

    // 测试接缝：注入 cursor 操控与 post 调用，纯逻辑测试不真的动光标。
    var cursorOps: CursorOps = .system

    /// mouseDown 与 mouseUp 之间的按压时长。
    /// 按帧轮询输入的目标（Unity / UE，如 PlayCover 上的崩坏：星穹铁道）观察不到零时长的
    /// 按下——down 与 up 落在同一次轮询间隔内，等同于按钮从未被按过。
    /// 实测：0ms 完全无响应，32ms 起正常。
    ///
    /// v1.6.3：App Store 正版「设计给 iPad」游戏（问道手游、阴阳师）反馈方案 B 里指针
    /// 来回跳的位移感明显——不是 hover 高亮的渐变动画，是指针本身物理位移，跳动时长
    /// 与 dwell 近似线性相关。原先 50ms（≈3 帧 @60fps）在 32ms 实测底线上留了 18ms 余量；
    /// 收到 40ms（留 8ms 余量，仍扛得住掉到 30fps 时的 1 帧轮询窗口），视觉跳动时长
    /// 缩短约 20%。这个值是所有 iOS-on-Mac 游戏共用的，调低前后都需要在崩坏：星穹铁道
    /// 这类按帧轮询输入的 PlayCover 游戏上验证点击可靠性没有退化。
    static let clickDwell: TimeInterval = 0.04

    /// 光标离点击点多远（点）才值得为这次点击隐藏光标。
    ///
    /// 隐藏不是免费的：指针会凭空消失整个 dwell（40ms）。对「边玩边按映射键」的玩家，
    /// 准星每按一次键就闪掉一次，比 sprite 挪一小段更难受——这正是「鼠标闪烁」的主要来源。
    /// 位移小到这个范围内时肉眼分辨不出来，直接不藏，代价为零。
    ///
    /// 20 点 ≈ 一个标准光标的高度：再大就能看出指针「跳」了一下。
    /// 注意隐藏跳过后 `associate(false)` / `warp` 依然照做——那两步是防止真实鼠标
    /// 在投递期间把点击带偏的保护，与视觉无关，任何情况下都不能省。
    static let cursorHideDistanceThreshold: CGFloat = 20

    /// 点击投递专用串行队列。
    ///
    /// 整段 mouseMoved→down→停留→up→还原 必须在**同一个自始至终不让出 run loop 的线程**
    /// 上同步跑完。实测：光标 disassociate 期间只要让出 run loop（例如把 mouseUp 放进
    /// main queue 的 asyncAfter），PlayCover 就收不到成对的按下/抬起，点击整个失效——
    /// 同样的序列改成阻塞式 sleep 立刻恢复正常。所以这里用后台线程 + 同步 sleep：
    /// 既满足「不让出」，又不阻塞主线程上的事件 tap。
    ///
    /// 串行还顺带保证连击不会交错各自的 associate / warp，无需额外的重入保护。
    nonisolated private static let clickQueue = DispatchQueue(
        label: "com.keysmirror.ClickSimulator.click",
        qos: .userInteractive
    )

    /// 生产执行器：异步派发到 clickQueue（闭包内部是同步阻塞的）。抽成 static 供测试还原。
    nonisolated(unsafe) static let defaultRunner: (@escaping () -> Void) -> Void = { work in
        let boxed = UnsafeWork(run: work)
        clickQueue.async { boxed.run() }
    }

    // 测试接缝：注入投递序列的执行方式。单测换成同步执行，调用顺序断言即可成立。
    var runClickSequence: (@escaping () -> Void) -> Void = ClickSimulator.defaultRunner

    // 测试接缝：注入按压停留。单测换成空实现，避免真的睡 50ms。
    var sleepForDwell: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    /// 强制让 iOS-on-Mac 应用走方案 A 的开关。
    ///
    /// 实测结论（2026-08，问道手游 com.gbits.atm.ios，App Store 正版「为 iPad 设计」应用）：
    /// **postToPid 对 iOS-on-Mac 运行时无效**。同一坐标关掉开关走方案 B 有响应、打开走方案 A
    /// 无响应，对照明确。原因是架构性的——「指针 → UITouch」的翻译由系统框架层完成，
    /// 而那一层订阅的是 session 级事件流；postToPid 恰好绕过它，事件进了进程却没人翻译。
    ///
    /// 因此**指针闪烁无法根除**，只能靠 clickDwell 收窄 + 点击期间隐藏光标来压缩。
    ///
    /// 2026-08-15 复测：App Store 版阴阳师（`Wrapper/` 布局，签名 Apple iPhone OS Application
    /// Signing）上同样无响应，与问道一致——**「App Store 设计给 iPad 版」这一类确定不认 postToPid**。
    ///
    /// ⚠️ **别把这个结论推广到 PlayCover 侧载应用**。这里原本写着「两类没有区别」，那是没有
    /// 依据的推断，且已经误导过一次排查：PlayCover 是把应用侧载成标准 macOS 应用、往进程里
    /// 注入代码自己 hook 输入，未必依赖系统兼容层那条 session 流。这个区别很关键——postToPid
    /// 完全绕开 Window Server，后台点击既不激活窗口也不动光标，正是「挂机不打扰用户」唯一
    /// 可能的实现路径。PlayCover 侧未验证，需要时用下面的开关实测，不要靠推断。
    ///
    /// 所以保留这个接缝做真机 A/B 对照：设环境变量 `KEYSMIRROR_FORCE_POSTTOPID=1` 启动即可
    /// 强制 iOS-on-Mac 目标走方案 A。默认仍是 false，不影响正常使用。
    var forcePostToPidProvider: () -> Bool = {
        ClickSimulator.forcePostToPid(environment: ProcessInfo.processInfo.environment)
    }

    /// 抽成纯函数便于单测：只有显式设成 "1" 才启用实验路径，其余一律 false。
    static func forcePostToPid(environment: [String: String]) -> Bool {
        environment["KEYSMIRROR_FORCE_POSTTOPID"] == "1"
    }

    /// session 投递的几种变体，用来找「点得中但不激活窗口」的组合。
    ///
    /// 到目前为止所有实验都只动了**事件源**（suppress 与否）和**进程标记**
    /// （`eventTargetUnixProcessID`），从没碰过事件自身的**窗口定位字段**，也没换过
    /// 投递端口。这两个都是公开 API，且正好是 Window Server 做「这一下该给谁、要不要
    /// 激活它」判断时会看的东西——没试过就断言「做不到」是不成立的。
    ///
    /// 用环境变量 `KEYSMIRROR_DELIVERY` 选择，默认 `standard`（现状，行为不变）。
    enum DeliveryMode: String {
        /// 现状：`.cgSessionEventTap` + 进程标记。
        case standard
        /// 换投递端口：`.cgAnnotatedSessionEventTap`。它比普通 session tap 多带一层窗口注解，
        /// 系统自己合成带窗口归属的事件时走的就是这条。
        case annotated
        /// 额外填上「这一下是给哪个窗口的」：`kCGMouseEventWindowUnderMousePointer` 与
        /// `...ThatCanHandleThisEvent`。真实鼠标事件里这两个字段由 Window Server 填，
        /// 合成事件默认是 0。填上之后它还做不做命中测试、还激不激活，正是要测的。
        case windowID
        /// 两者叠加。
        case annotatedWindowID

        nonisolated var tapLocation: CGEventTapLocation {
            switch self {
            case .annotated, .annotatedWindowID: return .cgAnnotatedSessionEventTap
            case .standard, .windowID: return .cgSessionEventTap
            }
        }

        nonisolated var setsWindowID: Bool {
            switch self {
            case .windowID, .annotatedWindowID: return true
            case .standard, .annotated: return false
            }
        }
    }

    /// 未识别的值一律退回 `standard`：实验开关绝不能因为拼错就把生产行为改掉。
    nonisolated static func deliveryMode(environment: [String: String]) -> DeliveryMode {
        environment["KEYSMIRROR_DELIVERY"].flatMap(DeliveryMode.init(rawValue:)) ?? .standard
    }

    /// `nonisolated`：启动时求值一次的 Sendable 常量，之后只读；而 `CursorOps.system` 的
    /// post 闭包要在 clickQueue（非主线程）上读它。
    nonisolated static let deliveryMode: DeliveryMode =
        ClickSimulator.deliveryMode(environment: ProcessInfo.processInfo.environment)

    /// 目标进程最大的那扇 layer-0 窗口的 window id。
    /// 取面积最大的，理由同 `WindowLocator.mainWindowFrame`：游戏进程常挂着输入法候选框
    /// 之类的小窗口，它们可能排在主窗口前面。
    nonisolated static func mainWindowID(ofPid pid: pid_t) -> CGWindowID? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, area: CGFloat)?
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let area = bounds.width * bounds.height
            if best == nil || area > best!.area { best = (number, area) }
        }
        return best?.id
    }

    /// 测试接缝：方案 A 的投递。与方案 B 的 `cursorOps` 对称，
    /// 让「走了哪条路径」可断言，且单测不会真的往进程里投递事件。
    var postToPid: (CGEvent, pid_t) -> Void = { event, pid in event.postToPid(pid) }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            // NSWorkspace notification 已在 main queue，直接 MainActor hop 修改缓存
            Task { @MainActor in
                self?.nativeCache.removeValue(forKey: bid)
            }
        }
    }

    /// - Parameter suppressLocalInput: 投递期间屏蔽物理鼠标事件，避免用户正在动鼠标时把这一击
    ///   挤掉。**仅目标不在前台的后台宏**该开；目标已在前台时绝不能开——否则会吞玩家鼠标，
    ///   和按键映射叠用时表现为鼠标闪/顿。前台映射同样保持关闭。
    /// - Parameter tagTargetProcess: 给 session 层事件打上目标进程标记
    ///   （`eventTargetUnixProcessID`）。事件依然走 session 流——iOS-on-Mac 运行时靠它维护
    ///   指针位置，绕不开。`movedBack` 靠它避免广播给光标下的别的 app。
    ///   ⚠️ 它**不能**阻止 Window Server 把被点到的后台窗口激活到前台；防激活靠调用方
    ///   在后台场景用 `completion` 还原前台，前台场景则根本不要走这套参数。
    /// - Parameter dwell: 按下与抬起之间的停留时长。传 nil 用全局默认 `clickDwell`。
    ///   每个应用配置可以覆盖它——见 `AppProfile.clickDwellMs`。
    /// - Parameter clickCount: 连击次数。**必须在这里传，不要在调用方 for 循环调多次**——
    ///   光标的「记下原位 → 移到点击点 → 还原」整套动作是按一次调用配平的，调多次就会
    ///   每次重新取一遍原位。而连击是零间隔背靠背投递的，第二次取原位时第一次的 warp
    ///   往往还没落定，取到的是已经被移过去的位置，最后就把光标还原到了点击点上——
    ///   表现为「鼠标箭头被拽到游戏里回不来」。合并成一次投递后原位只取一次，
    ///   hide/warp/associate 也只做一次，顺带少了几次光标抖动。
    /// - Parameter completion: 整个连击序列投递完成后在主线程执行**一次**的回调。
    ///   仅后台宏用于「若本次点击把目标顶到前台，则还原点击前的前台 app」。
    func leftClick(
        at point: CGPoint,
        targetApp: NSRunningApplication? = nil,
        dwell dwellOverride: TimeInterval? = nil,
        clickCount: Int = 1,
        suppressLocalInput: Bool = false,
        tagTargetProcess: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let repeats = max(1, clickCount)
        let source = suppressLocalInput ? suppressingEventSource : eventSource
        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up   = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
        else { return }

        let pid = targetApp?.processIdentifier ?? 0
        let isNative = targetApp.map { isNativeMacApp($0) } ?? true

        let dwell = Self.resolveDwell(dwellOverride)
        let sleep = sleepForDwell

        // 实验开关：iOS-on-Mac 应用本该走方案 B，开关打开时改走方案 A 做实机验证。
        // 只在真正改变了路由时记一笔日志，正常使用不产生噪音。
        let forced = !isNative && pid > 0 && forcePostToPidProvider()
        if forced {
            AppLogger.shared.log(
                "【实验】\(targetApp?.localizedName ?? "?") 本应走方案B(session)，已强制改走方案A(postToPid) pid=\(pid)",
                type: "ACTION"
            )
        }

        if pid > 0 && (isNative || forced) {
            // 方案 A：postToPid — 原生 macOS App
            // 完全绕过 Window Server，光标本身不会移动，无需任何光标管理。
            // 仍然走后台队列同步等待，好让按压跨过目标的输入轮询间隔。
            let post = postToPid
            let savedCompletion = completion
            runClickSequence {
                for _ in 0..<repeats {
                    post(down, pid)
                    sleep(dwell)
                    post(up, pid)
                }
                if let savedCompletion {
                    DispatchQueue.main.async { savedCompletion() }
                }
            }
        } else {
            // 方案 B：Session 层投递 — iOS-on-Mac App
            //
            // mouseDown 之前必须先补一个 mouseMoved。PlayCover 这类 iOS-on-Mac 运行时
            // 是**追踪鼠标移动事件流**来维护指针位置、再据此合成 UITouch 的，不会去查
            // 系统光标，也不看 mouseDown 自带的 mouseCursorPosition。缺了这一步，触摸
            // 就落在它记忆里的旧位置上（通常是用户光标所在处），点击等于打空。
            //
            // 注意：CGWarpMouseCursorPosition 不产生任何事件，对这类 app 是静默的、
            // 无效的——必须发真正的 mouseMoved 事件。反过来说，也就**不需要真的挪动
            // 光标**，「光标纹丝不动」的承诺在这条路径上依然成立。
            //
            // 实测（PlayCover 上的崩坏：星穹铁道）：无 mouseMoved 时任何按压时长都无效；
            // 补上 mouseMoved 后 32ms 起稳定触发。
            //
            // Window Server 仍会依据事件的 mouseCursorPosition 更新光标，所以整段用
            // disassociate 冻结、末尾 warp 回原位再 re-associate。顺序不能变：先 warp
            // 再 re-associate，否则会有一帧光标停在 click 点造成视觉抖动。
            //
            // 整段跑在 clickQueue 上（见其注释）：中途一旦让出 run loop，PlayCover
            // 就收不到成对的按下/抬起。
            guard let moved = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
            // down 与 up 之间再钉一次位置：万一有真实 move 挤进来，抬起也不会跑到别处，
            // 否则目标只收到半个手势（按下有效、抬起落在别处），点击照样失败。
            let reassert = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            if tagTargetProcess, pid > 0 {
                for event in [moved, down, up, reassert].compactMap({ $0 }) {
                    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
                }
            }
            // 实验：把「这一下是给哪扇窗口的」显式写进事件。真实鼠标事件里这两个字段由
            // Window Server 填，合成事件默认为 0——也就是说我们一直在让它自己去做命中测试，
            // 而命中测试正是「点了未激活的窗口 → 激活它」那条路径的入口。
            if Self.deliveryMode.setsWindowID, pid > 0, let windowID = Self.mainWindowID(ofPid: pid) {
                for event in [moved, down, up, reassert].compactMap({ $0 }) {
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
                }
            }
            let ops = cursorOps

            let audit = tagTargetProcess
            let tagPid: pid_t = tagTargetProcess ? pid : 0
            let auditName = targetApp?.localizedName ?? "?"
            let savedCompletion = completion
            runClickSequence {
                if audit {
                    Task { @MainActor in
                        AppLogger.shared.log("【点击·投递开始】\(auditName) @(\(Int(point.x)),\(Int(point.y)))", type: "ACTION")
                    }
                }
                let savedPos = ops.currentLocation()
                // 先隐藏光标再动它：disassociate 期间 Window Server 仍会按事件携带的
                // mouseCursorPosition 把指针 sprite 挪到点击点，哪怕已 warp 回原位收尾，
                // 中间那一帧真实可见——用户看到的就是「点一下鼠标闪一下」。隐藏起来，
                // 整段跳到点击点再跳回来的过程就没有画面，warp 完成后立即取消隐藏。
                //
                // 但位移小到看不出来时就别藏了：隐藏本身要让指针消失整个 dwell，
                // 比那点位移更扎眼（见 cursorHideDistanceThreshold）。
                let travel = hypot(point.x - savedPos.x, point.y - savedPos.y)
                let shouldHideCursor = travel > Self.cursorHideDistanceThreshold
                if shouldHideCursor { ops.hide() }
                ops.associate(false)
                // 连击整个跑在这一次 disassociate 区间里：原位只取一次（上面那行），
                // 中途绝不重新取，否则会取到已经被移到点击点的位置（见 clickCount 的说明）。
                for _ in 0..<repeats {
                    ops.post(moved)
                    ops.post(down)
                    sleep(dwell)
                    if let reassert { ops.post(reassert) }
                    ops.post(up)
                }
                // 把目标 app 内部记的指针也送回原处，避免在按钮上留下 hover 态。
                //
                // 这一条**必须**和前面四个事件一样打上目标进程标记：它的坐标是用户光标的真实
                // 位置，不打标记就会广播给光标底下的任何应用——用户在浏览器看视频时，
                // 播放器会把它当成"用户动了鼠标"，每跑一步宏就弹一次进度条。
                if let movedBack = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: savedPos, mouseButton: .left) {
                    if tagPid > 0 {
                        movedBack.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(tagPid))
                    }
                    ops.post(movedBack)
                }
                ops.warp(savedPos)
                ops.associate(true)
                if shouldHideCursor { ops.unhide() }
                if audit {
                    Task { @MainActor in
                        AppLogger.shared.log("【点击·投递结束】\(auditName)", type: "ACTION")
                    }
                }
                if let savedCompletion {
                    DispatchQueue.main.async { savedCompletion() }
                }
            }
        }
    }

    // MARK: - Internal (testable)

    /// 单次按压时长的合法区间。
    ///
    /// 下限 20ms：实测 32ms 是按帧轮询输入（PlayCover 上的崩坏：星穹铁道）的可靠底线，
    /// 20ms 已经进入「掉帧时可能整个漏掉这次按下」的区域，再低就不是调优而是坏掉了。
    /// 上限 200ms：超过这个值目标 app 会开始把它当成长按。
    static let dwellRange: ClosedRange<TimeInterval> = 0.02...0.2

    /// 把每应用覆盖值收进合法区间；没给覆盖值就用全局默认。
    /// 配置文件是用户可手改的 JSON，这里必须兜底，不能相信写进来的数。
    static func resolveDwell(_ override: TimeInterval?) -> TimeInterval {
        guard let override else { return clickDwell }
        return min(max(override, dwellRange.lowerBound), dwellRange.upperBound)
    }

    /// 判断是否为原生 macOS App（非 iOS-on-Mac）
    /// iOS App 的 Info.plist 中会包含 LSRequiresIPhoneOS = true
    func isNativeMacApp(_ app: NSRunningApplication) -> Bool {
        if let bid = app.bundleIdentifier, let cached = nativeCache[bid] {
            return cached
        }
        let result = computeIsNativeMacApp(app)
        if let bid = app.bundleIdentifier {
            nativeCache[bid] = result
        }
        return result
    }

    /// 测试用：手动清空缓存
    func clearNativeCacheForTesting() {
        nativeCache.removeAll()
    }

    /// 测试可注入的光标 / Session post 操作集合。production 用 `.system` 走真正的 CG 调用，
    /// 测试可换成记录式实现验证调用顺序。@unchecked Sendable：CG 函数本身线程安全，
    /// 测试用闭包仅 main thread 访问。
    struct CursorOps: @unchecked Sendable {
        var currentLocation: () -> CGPoint
        var associate: (Bool) -> Void
        var warp: (CGPoint) -> Void
        var post: (CGEvent) -> Void
        // 默认空实现：老测试字面量不用改就能继续编译，且不会往 calls 数组里记一笔。
        var hide: () -> Void = {}
        var unhide: () -> Void = {}

        static let system = CursorOps(
            currentLocation: { CGEvent(source: nil)?.location ?? .zero },
            associate: { connected in CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0) },
            warp: { CGWarpMouseCursorPosition($0) },
            // 投递端口由实验模式决定，默认 .cgSessionEventTap（现状）。
            post: { $0.post(tap: ClickSimulator.deliveryMode.tapLocation) },
            hide: { CGDisplayHideCursor(CGMainDisplayID()) },
            unhide: { CGDisplayShowCursor(CGMainDisplayID()) }
        )
    }

    private func computeIsNativeMacApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else {
            return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
        }

        // 三种 bundle 布局都要探：
        //   macOS       → Foo.app/Contents/Info.plist
        //   PlayCover   → Foo.app/Info.plist                                （扁平布局）
        //   App Store   → Foo.app/Wrapper/<原始 iOS 产物名>.app/Info.plist   （Apple 官方
        //                 「iPhone / iPad 兼容 App」在 Apple Silicon 上的包装格式，Foo.app/
        //                 WrappedBundle 是指向 Wrapper/ 内真实 .app 的符号链接）
        // 只查前两种会让 App Store 版「设计给 iPad 的游戏」读不到 plist，退化到 ".ios" 后缀
        // 后备判断；而 com.netease.onmyoji 这类 bundleId 并没有该后缀，会被误判成原生 App
        // 走 postToPid——绕过了 iOS-on-Mac 分支专门做的光标隐藏，表现为点击时光标可见地
        // 跳一下（阴阳师、问道手游等 App Store 版都是这个 Wrapper 布局）。
        var candidates = [
            bundleURL.appendingPathComponent("Contents").appendingPathComponent("Info.plist"),
            bundleURL.appendingPathComponent("Info.plist"),
        ]
        let wrappedBundleLink = bundleURL.appendingPathComponent("WrappedBundle")
        if FileManager.default.fileExists(atPath: wrappedBundleLink.path) {
            let resolved = wrappedBundleLink.resolvingSymlinksInPath()
            candidates.append(resolved.appendingPathComponent("Info.plist"))
        }

        for url in candidates {
            guard let plist = infoPlistProvider(url) else { continue }
            if let requiresIPhoneOS = plist["LSRequiresIPhoneOS"] as? Bool {
                return !requiresIPhoneOS
            }
            // 后备判定：部分 PlayCover 游戏不含 LSRequiresIPhoneOS，但 DTPlatformName /
            // UIDeviceFamily 仍保留了 iOS 特征。不额外检查会误走 postToPid 导致点击完全无响应。
            // （注：这里原先举的例子是「阴阳师 com.netease.onmyoji」，但同一个 bundleId 既可能
            // 是 PlayCover 侧载版、也可能是 App Store「设计给 iPad」版，**光看 bundleId 判断不了
            // 是哪一种**——要看 bundle 布局：`Wrapper/`+`WrappedBundle` 是 App Store 版，
            // 根目录直接放 Info.plist 是 PlayCover 版。别再用 bundleId 反推运行时类型。）
            if let platform = plist["DTPlatformName"] as? String,
               platform.lowercased().contains("iphoneos") {
                return false
            }
            if let deviceFamily = plist["UIDeviceFamily"] as? [Any], !deviceFamily.isEmpty {
                return false
            }
            // 读到了 plist 且无任何 iOS 特征 → 按 macOS 原生处理
            return true
        }

        return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
    }
}

/// 把非 Sendable 的闭包（捕获了 CGEvent）搬到 main queue 上执行。
/// 与 PointRecorder 里的 UnsafeOptionalEvent 同一思路：CG 类型本身线程安全，
/// 且此闭包仅在 main thread 运行。
private struct UnsafeWork: @unchecked Sendable {
    let run: () -> Void
}
