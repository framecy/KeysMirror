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

    // 测试接缝：注入 Info.plist 读取与 App 枚举逻辑
    var infoPlistProvider: (URL) -> NSDictionary? = { NSDictionary(contentsOf: $0) }

    // 测试接缝：注入 cursor 操控与 post 调用，纯逻辑测试不真的动光标。
    var cursorOps: CursorOps = .system

    /// mouseDown 与 mouseUp 之间的按压时长。
    /// 按帧轮询输入的目标（Unity / UE，如 PlayCover 上的崩坏：星穹铁道）观察不到零时长的
    /// 按下——down 与 up 落在同一次轮询间隔内，等同于按钮从未被按过。
    /// 实测：0ms 完全无响应，32ms 起正常。取 50ms ≈ 3 帧 @60fps（掉到 30fps 也有 1.5 帧），
    /// 既跨得过轮询间隔，又把方案 B 里光标离位的时间压到基本看不见，
    /// 且远低于长按手势阈值（通常 500ms）。
    static let clickDwell: TimeInterval = 0.05

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

    func leftClick(at point: CGPoint, targetApp: NSRunningApplication? = nil) {
        guard
            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up   = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
        else { return }

        let pid = targetApp?.processIdentifier ?? 0
        let isNative = targetApp.map { isNativeMacApp($0) } ?? true

        let dwell = Self.clickDwell
        let sleep = sleepForDwell

        if pid > 0 && isNative {
            // 方案 A：postToPid — 原生 macOS App
            // 完全绕过 Window Server，光标本身不会移动，无需任何光标管理。
            // 仍然走后台队列同步等待，好让按压跨过目标的输入轮询间隔。
            runClickSequence {
                down.postToPid(pid)
                sleep(dwell)
                up.postToPid(pid)
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
            guard let moved = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { return }
            let source = eventSource
            let ops = cursorOps

            runClickSequence {
                let savedPos = ops.currentLocation()
                ops.associate(false)
                ops.post(moved)
                ops.post(down)
                sleep(dwell)
                ops.post(up)
                // 把目标 app 内部记的指针也送回原处，避免在按钮上留下 hover 态
                if let movedBack = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: savedPos, mouseButton: .left) {
                    ops.post(movedBack)
                }
                ops.warp(savedPos)
                ops.associate(true)
            }
        }
    }

    // MARK: - Internal (testable)

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

        static let system = CursorOps(
            currentLocation: { CGEvent(source: nil)?.location ?? .zero },
            associate: { connected in CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0) },
            warp: { CGWarpMouseCursorPosition($0) },
            post: { $0.post(tap: .cgSessionEventTap) }
        )
    }

    private func computeIsNativeMacApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else {
            return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
        }

        // 两种 bundle 布局都要探：
        //   macOS  → Foo.app/Contents/Info.plist
        //   iOS    → Foo.app/Info.plist          （PlayCover 安装的就是这种扁平布局）
        // 只查 Contents/ 会让 PlayCover 应用读不到 plist，退化到 ".ios" 后缀后备判断；
        // 而 com.miHoYo.hkrpg 这类 bundleId 并没有该后缀，就会被误判成原生 App 走
        // postToPid——iOS-on-Mac 应用收不到那条路径的事件，表现为点击完全无响应。
        let candidates = [
            bundleURL.appendingPathComponent("Contents").appendingPathComponent("Info.plist"),
            bundleURL.appendingPathComponent("Info.plist"),
        ]

        for url in candidates {
            guard let plist = infoPlistProvider(url) else { continue }
            if let requiresIPhoneOS = plist["LSRequiresIPhoneOS"] as? Bool {
                return !requiresIPhoneOS
            }
            // 读到了 plist 但没有该键 → 按 macOS 原生处理
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
