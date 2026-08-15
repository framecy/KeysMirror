import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// `MacroRunner.runningMacroId` 变化时广播；StatusBarController 据此更新菜单栏。
    static let macroRunStateDidChange = Notification.Name("KeysMirror.MacroRunStateDidChange")
}

/// 一条正在运行的宏的对外快照（菜单栏滚动条直接消费）。
struct RunningMacro: Identifiable, Equatable {
    let id: UUID
    let label: String
    let bundleId: String
    /// 已完成的轮次
    var iteration: Int
    /// 总轮次；nil = 无限循环（UI 显示 ∞）
    var total: Int?
}

/// 并行执行多条宏：每条宏一个独立 Task，互不影响。
/// 取消通过 `Task.cancel()` 实现，长 sleep 也会立即结束。
@MainActor
final class MacroRunner: ObservableObject {
    static let shared = MacroRunner()

    /// 运行中的宏，按启动先后排列（菜单栏滚动展示依赖这个顺序保持稳定）。
    @Published private(set) var running: [RunningMacro] = []

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let logger = AppLogger.shared

    /// 挂起中的「还原前台」。见 `scheduleFrontmostRestore`。
    private var pendingRestore: Task<Void, Never>?

    /// 「前台是宏自己抢来的」这件事的记账。
    ///
    /// 没有它就只能看 `NSWorkspace.frontmostApplication`，而后台宏点第一下就会把目标顶到
    /// 前台——第二步再看，目标「在前台」，于是被当成用户自己切过去的，后台保护全部关掉。
    /// 记下「被抢之前用户在哪个 app」才能把前台还对地方。
    private struct UsurpedFront {
        /// 被宏抢走前台之前，用户真正所在的那个 app。
        let previous: NSRunningApplication
        /// 抢走前台的那个目标进程。
        let targetPid: pid_t
    }

    private var usurpedFront: UsurpedFront?

    /// 最近一次后台点击的投递时刻。用来判断「目标被激活」到底是这一击造成的，还是用户自己切过去的。
    private var lastBackgroundClickAt: Date?

    /// 连续 150ms 内没有新的后台点击，才认为这一阵子点完了，可以把前台还回去。
    /// 取这个值是因为最短的宏步间隔通常也在百毫秒量级；再短会让还原和下一步点击打架，
    /// 再长则用户会觉得「点完半天才切回来」。
    static let restoreDebounce: TimeInterval = 0.15

    /// 实验开关：跳过「点击点被别的窗口盖住就不点」这条安全网。
    /// 设 `KEYSMIRROR_IGNORE_OCCLUSION=1` 启用，默认关闭。
    ///
    /// 要验证的是：打了 `eventTargetUnixProcessID` 标记的 session 事件到底按什么路由——
    /// 按**光标位置**（会打进盖在上面的那个窗口）还是按 **pid**（能穿透遮挡打中目标）。
    /// 目标没被盖住时两种路由的结果完全一样，看不出区别；**被覆盖是唯一能区分它们的场景**。
    /// 结论决定这条安全网是必需品还是多余的限制。
    ///
    /// ⚠️ 打开后点击可能真的打进用户自己的窗口，只在受控测试时用。
    static let ignoreOcclusion: Bool =
        ProcessInfo.processInfo.environment["KEYSMIRROR_IGNORE_OCCLUSION"] == "1"

    /// 后台目标被唤到前台后，等多久再投递点击。
    ///
    /// iOS-on-Mac 应用在后台会被系统限流（降帧、暂停输入处理）。原先的顺序是「点击 → 系统
    /// 因为这一下把窗口激活」，也就是说点击恰好落在游戏刚被唤醒、还没缓过来的那一瞬间，
    /// 于是偶尔整个漏掉——用户看到的就是「宏跑着跑着丢了几步」。
    ///
    /// 反正这一下点击**必然**会把它激活（Window Server 的行为，拦不住），那就别让激活和
    /// 点击撞在一起：先主动激活、等它缓过来，再点。代价是焦点被占用的时间多了这么长。
    /// 0.15s ≈ 9 帧 @60fps，够一个被限流的 iOS 应用恢复正常输入处理。
    static let activationSettle: TimeInterval = 0.15

    /// 后台点击投递后多久之内的「目标被激活」算宏干的。
    ///
    /// Window Server 因点击激活窗口就发生在投递期间（见 ActivationAuditor 的取证说明，
    /// 激活紧跟 down 之后几毫秒）。超出这个宽限期还收到激活，只能是用户自己切过去的——
    /// 那就必须立刻停止「还原前台」，否则用户前脚点开游戏、后脚就被宏踢回原来的窗口。
    /// 0.2s = dwell(≤0.2) 的量级 + 通知投递抖动，取到刚好覆盖一次投递。
    static let macroActivationGrace: TimeInterval = 0.2

    /// 已经就「目标在后台被跳过」记过日志的宏。防止无限循环宏把日志刷屏。
    private var skipLoggedMacroIds: Set<UUID> = []

    /// 同上，但记的是「因为被别的窗口盖住而跳过」。两者分开：一条是「目标不在前台」，
    /// 一条是「目标被挡住」，成因和解法都不同，合用一个标记会互相压掉对方的提示。
    private var occlusionLoggedMacroIds: Set<UUID> = []

    var isAnyRunning: Bool { !running.isEmpty }

    func isRunning(_ macroId: UUID) -> Bool {
        running.contains { $0.id == macroId }
    }

    private init() {
        // 目标 app 退出 → 立即停，避免对着已消失的窗口空转
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppTerminated),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        // 用户自己切到目标窗口 → 放弃「把前台还回去」，别把人踢出来
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivated),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// 同一条宏再按其触发键 → 停；否则启动。各条宏互不干扰，可同时运行多条。
    func toggle(_ macro: MacroAction, profile: AppProfile) {
        if isRunning(macro.id) {
            stop(macroId: macro.id, reason: "用户再按触发键")
            return
        }
        startInternal(macro, profile: profile)
    }

    /// 停止指定的一条宏。
    func stop(macroId: UUID, reason: String? = nil) {
        guard let task = tasks.removeValue(forKey: macroId) else { return }
        task.cancel()
        if let label = running.first(where: { $0.id == macroId })?.label {
            logger.log("【宏停止】\(label)\(reason.map { "（\($0)）" } ?? "")", type: "ACTION")
        }
        running.removeAll { $0.id == macroId }
        skipLoggedMacroIds.remove(macroId)
        occlusionLoggedMacroIds.remove(macroId)
        if running.isEmpty { forgetStolenFront() }
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)
    }

    /// 停止全部宏（退出 / 休眠唤醒 / 菜单栏「全部停止」）。
    func stopAll(reason: String? = nil) {
        guard !tasks.isEmpty else { return }
        for id in Array(tasks.keys) {
            tasks.removeValue(forKey: id)?.cancel()
        }
        for macro in running {
            logger.log("【宏停止】\(macro.label)\(reason.map { "（\($0)）" } ?? "")", type: "ACTION")
        }
        running.removeAll()
        skipLoggedMacroIds.removeAll()
        occlusionLoggedMacroIds.removeAll()
        forgetStolenFront()
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)
    }

    /// 全部宏都停了就没有「还原前台」的语义了——挂起中的那次必须取消，
    /// 否则用户手动停完宏、自己切到别的窗口，150ms 后前台会被莫名其妙抢走。
    private func cancelPendingRestore() {
        pendingRestore?.cancel()
        pendingRestore = nil
    }

    /// 连同「前台是我们抢来的」这笔账一起清掉。
    ///
    /// 停宏时**不**顺手把前台还回去：后台宏的触发键只在目标处于前台时才拦得到
    /// （见 KeyInterceptor），也就是说用户是切到目标窗口才按下停止的——这时候再把前台
    /// 弹回原来的 app，等于刚停下宏就被踢出游戏。
    private func forgetStolenFront() {
        cancelPendingRestore()
        usurpedFront = nil
        lastBackgroundClickAt = nil
    }

    // MARK: - Pure helpers (testable)

    /// repeatCount 语义：0 = 无限（Int.max），N>=1 = N 次，其他（理论上不该出现）保底 1。
    static func computeStepCount(repeatCount: Int) -> Int {
        if repeatCount == 0 { return Int.max }
        return max(1, repeatCount)
    }

    /// 解析单步的窗口内偏移坐标。
    /// - .mapping(id) → 在 profile.mappings 中查 id，返回该 mapping 在指定 windowSize 下的偏移；找不到返回 nil
    /// - .inline(x,y,refW,refH) → 用临时 KeyMapping 走与映射相同的缩放算法
    static func resolvePosition(step: MacroStep, profile: AppProfile, windowSize: CGSize) -> CGPoint? {
        switch step.position {
        case .mapping(let mappingId):
            guard let referenced = profile.mappings.first(where: { $0.id == mappingId }) else {
                return nil
            }
            return referenced.absoluteOffset(in: windowSize)
        case .inline(let x, let y, let refW, let refH):
            let temp = KeyMapping(
                relativeX: x,
                relativeY: y,
                label: "",
                referenceWidth: refW,
                referenceHeight: refH
            )
            return temp.absoluteOffset(in: windowSize)
        }
    }

    /// 在窗口内偏移 `offset` 周围施加区域漂移。
    /// driftPercent<=0 时原样返回（精确点击）。否则在 x/y 各自 ±(driftPercent% × 窗口对应边长) 内均匀取偏移，
    /// 结果 clamp 回窗口范围内——保证漂移后依然落在窗口内，不会误触后台。
    /// `random` 注入 [-1,1] 的均匀采样，生产用 `Double.random(in:)`，测试注入确定值。
    static func applyDrift(
        toOffset offset: CGPoint,
        driftPercent: Double,
        windowSize: CGSize,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> CGPoint {
        guard driftPercent > 0, windowSize.width > 0, windowSize.height > 0 else { return offset }
        let frac = driftPercent / 100.0
        let dx = windowSize.width * frac * random(-1...1)
        let dy = windowSize.height * frac * random(-1...1)
        let x = min(max(offset.x + dx, 0), windowSize.width)
        let y = min(max(offset.y + dy, 0), windowSize.height)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Internal

    private func startInternal(_ macro: MacroAction, profile: AppProfile) {
        guard !macro.steps.isEmpty else {
            logger.log("宏 [\(macro.label)] 没有步骤，不执行", type: "WARN")
            return
        }

        let totalIterations = Self.computeStepCount(repeatCount: macro.repeatCount)
        running.append(RunningMacro(
            id: macro.id,
            label: macro.label,
            bundleId: profile.bundleIdentifier,
            iteration: 0,
            total: totalIterations == Int.max ? nil : totalIterations
        ))
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)

        logger.log("【宏启动】\(macro.label) | \(macro.steps.count) 步 × \(macro.repeatCount == 0 ? "无限" : "\(totalIterations)") 次 | \(profile.appName)", type: "ACTION")
        if Self.ignoreOcclusion {
            logger.log("【实验】已关闭遮挡安全网：被别的窗口盖住时也照样投递，用于验证事件按位置还是按 pid 路由", type: "WARN")
        }
        if ClickSimulator.deliveryMode != .standard {
            logger.log("【实验】投递方式 = \(ClickSimulator.deliveryMode.rawValue)（默认 standard）。关注两点：游戏有没有反应、投递后有没有【前台】切到目标", type: "WARN")
        }

        let macroId = macro.id
        let bundleId = profile.bundleIdentifier
        tasks[macroId] = Task { [weak self] in
            await self?.run(macroId: macroId, bundleId: bundleId)
        }
    }

    /// 每轮开始时重新从 store 读取宏定义——运行中编辑并保存的新配置会在下一轮生效。
    /// 不做「每步重读」：那样同一轮内的步骤可能来自不同版本的配置，行为难以预期。
    private func currentMacro(id: UUID, bundleId: String) -> MacroAction? {
        MappingStore.shared.profiles
            .first { $0.bundleIdentifier.lowercased() == bundleId.lowercased() }?
            .macros.first { $0.id == id }
    }

    private func run(macroId: UUID, bundleId: String) async {
        var iteration = 0

        while !Task.isCancelled {
            // 重新取配置：支持运行中编辑；宏被删除 / 禁用则自然停止
            guard let macro = currentMacro(id: macroId, bundleId: bundleId) else {
                stop(macroId: macroId, reason: "宏已被删除")
                return
            }
            guard macro.isEnabled else {
                stop(macroId: macroId, reason: "宏已被禁用")
                return
            }
            guard !macro.steps.isEmpty else {
                stop(macroId: macroId, reason: "宏已没有步骤")
                return
            }

            // 轮次上限同样每轮重算，改了重复次数也能即时反映
            let totalIterations = Self.computeStepCount(repeatCount: macro.repeatCount)
            if iteration >= totalIterations {
                logger.log("【宏完成】\(macro.label)（执行 \(totalIterations) 次）", type: "ACTION")
                stop(macroId: macroId)
                return
            }
            iteration += 1
            updateProgress(macroId: macroId, iteration: iteration, totalIterations: totalIterations)

            // 每轮开始刷新一次窗口位置即可。原先放在 fireStep 里逐步刷新，等于每步都强制一次
            // 主线程同步 AX 查询——对 AX 无响应的 app（阴阳师 / 问道）会长时间阻塞主线程，
            // 表现为整个 KeysMirror 界面点不动。窗口在一轮之内几乎不可能被移动，按轮刷新足够。
            WindowLocator.shared.invalidateFrameCache()

            // 无条件让出一次：若某个宏的所有步骤延迟都是 0，下面的 for 里就没有任何 await，
            // 这个 MainActor 隔离的循环会永不挂起、独占主线程，整个 App 直接冻死。
            await Task.yield()

            for (index, step) in macro.steps.enumerated() {
                if Task.isCancelled { return }

                if step.delaySeconds > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(step.delaySeconds * 1_000_000_000))
                    } catch {
                        return  // cancelled during sleep
                    }
                    if Task.isCancelled { return }
                }

                await fireStep(
                    step,
                    stepIndex: index,
                    iteration: iteration - 1,
                    totalIterations: totalIterations,
                    macro: macro,
                    bundleId: bundleId
                )
            }
        }
    }

    private func updateProgress(macroId: UUID, iteration: Int, totalIterations: Int) {
        guard let index = running.firstIndex(where: { $0.id == macroId }) else { return }
        running[index].iteration = iteration
        running[index].total = totalIterations == Int.max ? nil : totalIterations
        // 必须广播：菜单栏跑马灯不是 SwiftUI，订阅不到 @Published 的变化，
        // 只认这个通知。漏了它次数就永远停在启动时的值（表现为「状态栏数据不刷新」）。
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)
    }

    private func fireStep(
        _ step: MacroStep,
        stepIndex: Int,
        iteration: Int,
        totalIterations: Int,
        macro: MacroAction,
        bundleId: String
    ) async {
        // 这里只要求进程还活着；「要不要求它在前台」由下面的 backgroundMacroPolicy 决定。
        //
        // ⚠️ 历史遗留的错误认知（v1.7.0 的后台宏就是被它误导设计出来的）：曾以为 session 层
        // 投递「在后台也能点中且不抢焦点」。实测不成立——session 事件按「点到了谁的窗口」路由，
        // 被点到的后台窗口会被 Window Server 激活到前台，`eventTargetUnixProcessID` 标记拦不住。
        // 详见 ClickSimulator.leftClick 的参数说明。
        guard let targetApp = AppResolver.shared.runningApplication(bundleIdentifier: bundleId) else {
            stop(macroId: macro.id, reason: "目标 app 已退出")
            return
        }

        // 前台判定提前到这里：策略是「仅前台执行」时可以直接跳过，
        // 省掉后面那次可能阻塞主线程的 AX 窗口查询。
        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetIsFront = frontApp?.processIdentifier == targetApp.processIdentifier
        let policy = PreferencesStore.shared.preferences.backgroundMacroPolicy

        // 目标此刻在前台，但那是宏上一步自己点上去的——不能当成「用户把目标切到了前台」。
        // 这是 v1.7.1 「允许后台执行时前台来回横跳 / 指针被抢」的直接成因，见 clickPlan。
        let frontStolenByMacro = targetIsFront
            && usurpedFront?.targetPid == targetApp.processIdentifier
            && usurpedFront?.previous.isTerminated == false

        // 首次判定要读一次 Info.plist，之后按 bundleId 命中缓存、零 I/O。
        // 必须放在跳过判定之前：原生 App 走 postToPid，后台点击对用户零副作用，不该被跳过。
        let targetIsNative = ClickSimulator.shared.isNativeMacApp(targetApp)
        let plan = Self.clickPlan(
            targetIsFront: targetIsFront,
            targetIsNative: targetIsNative,
            frontStolenByMacro: frontStolenByMacro
        )

        if Self.shouldSkipBecauseBackground(
            targetIsFront: targetIsFront,
            targetIsNative: targetIsNative,
            policy: policy
        ) {
            // 跳过而不是停止：用户切回目标就自然续跑，不用重新按一次触发键。
            // 每步都记日志太吵（无限循环宏会刷屏），交给节流日志只在状态变化时说一次。
            logSkippedBecauseBackground(macro: macro, frontAppName: frontApp?.localizedName)
            return
        }

        // 注意：这里**不能**强制刷新窗口位置缓存。AX 查询是主线程同步调用，对 AX 无响应的
        // app（阴阳师 / 问道）会长时间阻塞；逐步刷新会把主线程占满，整个 App 界面点不动。
        // 缓存的失效改为每轮一次，见 run() 里的 invalidateFrameCache。
        guard let windowFrame = WindowLocator.shared.focusedWindowFrame(for: bundleId) else {
            // 窗口最小化 / 隐藏时读不到 frame：跳过本步而不是停止，窗口恢复后能自然续跑
            logger.log("宏 [\(macro.label)] 第 \(stepIndex + 1) 步：找不到窗口，跳过", type: "WARN")
            return
        }

        // 解析位置：mapping 引用走原 KeyMapping 的缩放路径；inline 直接构造一个临时 KeyMapping 走同一路径
        guard let profile = MappingStore.shared.profiles.first(where: { $0.bundleIdentifier.lowercased() == bundleId.lowercased() }) else {
            logger.log("宏 [\(macro.label)] 第 \(stepIndex + 1) 步：profile 已删除，跳过", type: "WARN")
            return
        }
        guard let resolvedOffset = Self.resolvePosition(step: step, profile: profile, windowSize: windowFrame.size) else {
            logger.log("宏 [\(macro.label)] 第 \(stepIndex + 1) 步：引用的映射已删除，跳过", type: "WARN")
            return
        }

        // 区域漂移：每次触发在解析点周围随机偏移，clamp 回窗口内（详见 applyDrift）
        let driftedOffset = Self.applyDrift(
            toOffset: resolvedOffset,
            driftPercent: step.driftPercent,
            windowSize: windowFrame.size
        )

        let clickPoint = CoordinateConverter.absolutePoint(
            relativeX: driftedOffset.x,
            relativeY: driftedOffset.y,
            in: windowFrame
        )

        // 安全网 1：点击点必须落在窗口内（避免误唤后台 app）
        guard windowFrame.contains(clickPoint) else {
            logger.log("宏 [\(macro.label)] 第 \(stepIndex + 1) 步：点击点 (\(Int(clickPoint.x)),\(Int(clickPoint.y))) 落在窗口 \(Int(windowFrame.width))x\(Int(windowFrame.height)) 外，已跳过", type: "WARN")
            return
        }

        // 安全网 2：目标必须真的露在最上层。即使目标是前台 app，它的窗口也可能被别的
        // 浮动窗口盖住一角——session 层点击会直接打进那个窗口（浏览器的发送、编辑器的删除
        // 都可能被点到）。选了「允许后台执行」时这条尤其关键。
        //
        // 只对 session 投递成立（见 clickPlan.checksOcclusion）：原生 App 走 postToPid，
        // 事件直接进目标进程，上面盖着谁都收不到，查遮挡只会把后台宏全部误杀。
        if plan.checksOcclusion,
           let occluder = WindowLocator.shared.occludingApp(at: clickPoint, ownedBy: targetApp.processIdentifier) {
            guard Self.ignoreOcclusion else {
                // 节流：无限循环宏被盖住时每步都记会把日志刷爆，只在状态变化时说一次。
                logOccluded(macro: macro, stepIndex: stepIndex, point: clickPoint, occluder: occluder)
                return
            }
            // 实验模式：照样投递，但必须把「当时确实被盖住了」记下来——否则事后无法区分
            // 「穿透遮挡打中了目标」和「那个点本来就没被盖住」，日志就自证不了任何结论。
            // 紧跟其后的【前台】行就是答案：切到目标 = 按 pid 路由；切到遮挡者 = 按位置路由。
            logger.log(
                "【实验】点击点 (\(Int(clickPoint.x)),\(Int(clickPoint.y))) 确实被「\(occluder)」盖住，" +
                "安全网已关闭 → 照样投递。看下一行【前台】切到谁：切到目标=按 pid 路由（穿透遮挡），" +
                "切到「\(occluder)」=按位置路由（打错窗口）",
                type: "WARN"
            )
        }

        let iterText = totalIterations == Int.max ? "∞" : "\(iteration + 1)/\(totalIterations)"
        let driftText = step.driftPercent > 0 ? " 漂移\(String(format: "%.1f", step.driftPercent))%" : ""
        // 连击共用同一坐标（漂移只在进入本步时算一次），否则双击会被目标 app 拆成两次单击
        let clickCount = max(1, step.clickCount)
        let clickText = clickCount > 1 ? " ×\(clickCount)" : ""
        logger.log("【宏步骤】[\(macro.label)] \(iterText) - 第 \(stepIndex + 1)/\(macro.steps.count) 步\(driftText) → 点击 (\(Int(clickPoint.x)),\(Int(clickPoint.y)))\(clickText)", type: "ACTION")

        // ClickSimulator 内部走串行队列，连续调用天然依次投递，无需额外间隔。
        // 投递参数的全部差异收敛在上面那个 `plan` 里，便于单测锁死（见 MacroRunnerTests）。
        // 真的点出去了 → 清掉「已就跳过记过日志」的标记，下次再被跳过时还会提示一次。
        skipLoggedMacroIds.remove(macro.id)
        occlusionLoggedMacroIds.remove(macro.id)

        // 要还原的是「被抢走之前用户所在的那个 app」，不是此刻的前台。
        // 目标已经被上一步顶上来时，此刻的前台就是目标自己，直接拿它去还原是个空操作
        // （scheduleFrontmostRestore 第一个 guard 会挡掉），前台就再也回不去了。
        let previousApp: NSRunningApplication?
        if plan.restoresPreviousApp {
            if frontStolenByMacro {
                previousApp = usurpedFront?.previous
            } else {
                previousApp = frontApp
                if let frontApp {
                    usurpedFront = UsurpedFront(previous: frontApp, targetPid: targetApp.processIdentifier)
                }
            }
            lastBackgroundClickAt = Date()
        } else {
            previousApp = nil
        }

        // 目标在后台 → 先主动把它唤到前台，等它缓过来再点。
        //
        // 这一下点击**必然**会把窗口激活（Window Server 的行为，四种投递组合全试过，拦不住），
        // 原来的顺序等于让点击和激活撞在同一瞬间，而 iOS-on-Mac 应用在后台是被系统限流的
        // （降帧、暂停输入处理），刚被唤醒那几帧接不住这一下——表现就是「宏跑着跑着丢几步」。
        // 既然激活躲不掉，就别让它和点击抢时间：先激活、等稳、再点。
        if plan.restoresPreviousApp, !targetIsFront {
            AppResolver.shared.activate(targetApp)
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.activationSettle * 1_000_000_000))
            } catch {
                return  // 等待期间宏被停掉
            }
            if Task.isCancelled { return }
            // 等待期间用户可能把窗口挪了 / 目标退出了，这里不重新校验：窗口位置一轮刷新一次
            // （见 run()），而 150ms 内窗口被挪走的概率远低于每步重查 AX 带来的主线程阻塞代价。
        }

        // 连击交给 ClickSimulator 在**一次**投递序列里完成，不要在这里 for 循环调多次：
        // 那样每发都会重新取一次光标原位，而连击是零间隔的，第二发取到的往往是已经被移到
        // 点击点的位置，收尾就把鼠标箭头还原到了游戏里（见 leftClick 的 clickCount 说明）。
        ClickSimulator.shared.leftClick(
            at: clickPoint,
            targetApp: targetApp,
            dwell: profile.clickDwellSeconds,
            clickCount: clickCount,
            suppressLocalInput: plan.suppressLocalInput,
            tagTargetProcess: plan.tagTargetProcess,
            completion: plan.restoresPreviousApp ? { [weak self] in
                // 回调在整个连击投递完成后触发一次，此刻记时刻最贴近「最后一发落地」，
                // 后续的窗口激活才不会被误判成用户自己切过去的。
                self?.lastBackgroundClickAt = Date()
                self?.scheduleFrontmostRestore(to: previousApp, target: targetApp)
            } : nil
        )
        NotificationCenter.default.post(name: .inputActivityDidFire, object: nil)
    }

    /// 单次点击的投递参数。前台 / 后台 / 原生的全部差异都收敛在这里。
    struct ClickPlan: Equatable {
        /// 投递期间屏蔽物理鼠标事件。
        var suppressLocalInput: Bool
        /// 给 session 事件打目标进程标记（`movedBack` 靠它不广播给光标下的别的 app）。
        var tagTargetProcess: Bool
        /// 点完是否要把前台还给点击前那个 app。
        var restoresPreviousApp: Bool
        /// 点击前是否要确认目标窗口在该点没有被别的窗口盖住。
        var checksOcclusion: Bool
    }

    /// 目标已在前台（用户边玩边跑宏 + 按键映射）：必须和 KeyInterceptor 走同一条路径——
    /// 不开 `suppressLocalInput`（否则宏步会吞掉玩家的物理鼠标，和映射叠在一起就是「鼠标闪/顿」），
    /// 也不还原前台（游戏本来就在前台，再 activate 等于每步重抢一次焦点，
    /// 表现成「宏把游戏窗口又激活了一遍」）。
    ///
    /// 目标在后台（用户显式选了「允许后台执行」）：session 投递会把窗口顶到前台，
    /// 只能点完再还原。此时才需要 suppress + tag。
    ///
    /// - Parameter targetIsNative: 目标是原生 macOS App（走 `postToPid`）。这条路径完全绕开
    ///   Window Server：不动光标、不激活窗口、事件也不按「光标下是谁的窗口」路由，
    ///   这些开关全都是给 session 投递擦屁股用的，一个都不需要。
    ///   尤其 `suppressLocalInput` 每次点击会冻结用户的物理鼠标约一个 dwell——
    ///   后台跑无限循环宏时就是持续性的「鼠标被抢走」，而这里根本没有要防的东西；
    ///   而 `checksOcclusion` 更是会让原生 App 的后台宏一步都点不出去——用户在自己的窗口里
    ///   干活，那扇窗口天然盖在目标上面，每一步都会被判「被遮挡，已跳过」。
    ///   遮挡对 postToPid 不成立：事件直接进目标进程，上面盖着谁都收不到。
    /// - Parameter frontStolenByMacro: 目标此刻在前台，但那是**宏自己上一步点上去的**，
    ///   不是用户切过去的。必须仍按后台处理：否则「目标在前台」会一步步退化掉全部保护——
    ///   不再打 tag（收尾的 movedBack 广播给光标底下的 app）、不再刷新防抖还原
    ///   （挂起中的那次 150ms 后照样触发，紧接着又被下一步点击抢回去，前台开始来回横跳）。
    static func clickPlan(
        targetIsFront: Bool,
        targetIsNative: Bool = false,
        frontStolenByMacro: Bool = false
    ) -> ClickPlan {
        if targetIsNative {
            return ClickPlan(
                suppressLocalInput: false,
                tagTargetProcess: false,
                restoresPreviousApp: false,
                checksOcclusion: false
            )
        }
        let treatAsBackground = !targetIsFront || frontStolenByMacro
        return ClickPlan(
            suppressLocalInput: treatAsBackground,
            tagTargetProcess: treatAsBackground,
            restoresPreviousApp: treatAsBackground,
            // 前台目标也要查：目标虽在前台，它的窗口仍可能被别的浮动窗口盖住一角，
            // session 点击会直接打进那个窗口。见安全网 2。
            checksOcclusion: true
        )
    }

    /// 目标不在前台时，这一步该不该跳过。
    ///
    /// 「仅前台执行」这一档的**代价只存在于 iOS-on-Mac 应用**：它们的点击必须走 session 层，
    /// 而 session 事件会把被点到的后台窗口顶到前台，抢走用户的焦点。原生 macOS App 走
    /// `postToPid`，事件直接进目标进程——不动光标、不激活窗口、不受遮挡影响，在后台点击
    /// 对用户是零副作用的。对它也跳过纯属白白牺牲功能，所以这里放行。
    static func shouldSkipBecauseBackground(
        targetIsFront: Bool,
        targetIsNative: Bool,
        policy: BackgroundMacroPolicy
    ) -> Bool {
        guard !targetIsFront else { return false }
        guard policy == .frontmostOnly else { return false }
        return !targetIsNative
    }

    /// 还原前台——**防抖**，不是每步点完都立刻抢回去。
    ///
    /// 为什么必须防抖：宏的主循环不等点击投递完成就往下走。步骤间隔只有几十毫秒时，
    /// 第 N 步的「还原前台」会和第 N+1 步的点击（它又会把目标顶到前台）迎面撞上，
    /// 用户看到的就是前台在游戏和自己的窗口之间来回横跳。等到连续 `restoreDebounce`
    /// 内不再有新的后台点击，说明这一阵子点完了，这时候还一次即可。
    private func scheduleFrontmostRestore(to previousApp: NSRunningApplication?, target: NSRunningApplication) {
        // previous 就是目标自身 → 本来就没抢谁的焦点，不用还。
        guard let previousApp, previousApp.processIdentifier != target.processIdentifier else { return }

        pendingRestore?.cancel()
        let targetPid = target.processIdentifier
        pendingRestore = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.restoreDebounce * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pendingRestore = nil
            // 这一笔账到此结清：还原成功也好、发现不该还也好，「前台是我们抢来的」都不再成立。
            // 不清的话下一步点击会继续按「目标在前台但是我们抢的」走，永远还不回去。
            self.usurpedFront = nil
            // 只在目标确实还占着前台时才还原。用户在这段间隔里自己切走了 → 什么都别做，
            // 否则会把用户刚打开的窗口又抢掉。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else { return }
            guard previousApp.isTerminated == false else { return }
            AppResolver.shared.activate(previousApp)
        }
    }

    /// 判断一次「目标被激活」是不是宏自己造成的。
    /// 投递期间（几毫秒内）的激活是点击的副作用；宽限期之外的只能是用户自己切过去的。
    static func activationIsMacroCaused(
        activatedAt: Date,
        lastBackgroundClickAt: Date?,
        grace: TimeInterval = MacroRunner.macroActivationGrace
    ) -> Bool {
        guard let lastBackgroundClickAt else { return false }
        let gap = activatedAt.timeIntervalSince(lastBackgroundClickAt)
        return gap >= 0 && gap <= grace
    }

    /// 「被遮挡跳过」的日志节流。理由同 `logSkippedBecauseBackground`：用户的宏动辄几百轮，
    /// 窗口被盖住的整段时间里每步记一行会把日志淹掉，真正有用的行反而找不到。
    /// 只在从「点得出去」变成「被挡住」时说一次，并且把话说全——用户看到这行才知道
    /// 为什么宏不动了、以及该怎么办。
    private func logOccluded(macro: MacroAction, stepIndex: Int, point: CGPoint, occluder: String) {
        guard !occlusionLoggedMacroIds.contains(macro.id) else { return }
        occlusionLoggedMacroIds.insert(macro.id)
        logger.log(
            "宏 [\(macro.label)] 第 \(stepIndex + 1) 步：点击点 (\(Int(point.x)),\(Int(point.y))) 被「\(occluder)」盖住，已跳过。" +
            "这类应用的点击按「屏幕上那个位置是谁的窗口」投递，盖住了就会打进「\(occluder)」里去，" +
            "所以必须跳过。把目标窗口挪开或让它露出点击区域即可自动继续。",
            type: "WARN"
        )
    }

    /// 「跳过因为目标在后台」的日志节流：无限循环宏每轮都会走到这里，
    /// 不节流会把日志刷成一片。只在从「在跑」变成「被跳过」时说一次。
    private func logSkippedBecauseBackground(macro: MacroAction, frontAppName: String?) {
        guard !skipLoggedMacroIds.contains(macro.id) else { return }
        skipLoggedMacroIds.insert(macro.id)
        let front = frontAppName.map { "（当前前台：\($0)）" } ?? ""
        logger.log(
            "宏 [\(macro.label)] 目标不在前台，已跳过\(front)。切回目标窗口即自动继续；" +
            "要让它在后台也跑，去 设置 → 后台宏策略 改成「允许后台执行」——" +
            "代价是这类应用（iOS-on-Mac）的点击会被系统把窗口切到前台。",
            type: "WARN"
        )
    }

    // MARK: - 前台变化

    /// 用户自己把目标窗口切到前台 → 立刻放弃「还原前台」。
    ///
    /// 没有这一步的话：后台宏的触发键只在目标处于前台时才拦得到，用户为了停宏切回游戏，
    /// 挂起中的还原会在 150ms 后把他们弹回原来的窗口，看起来就是「点了游戏又被踢出来」。
    @objc private func handleAppActivated(_ note: Notification) {
        guard let usurped = usurpedFront,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier == usurped.targetPid else { return }
        guard !Self.activationIsMacroCaused(
            activatedAt: Date(),
            lastBackgroundClickAt: lastBackgroundClickAt
        ) else { return }
        logger.log("【前台】\(app.localizedName ?? "目标") 是你自己切过去的，已取消挂起的前台还原", type: "ACTION")
        cancelPendingRestore()
        usurpedFront = nil
    }

    @objc private func handleAppTerminated(_ note: Notification) {
        guard let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let quitBundle = quit.bundleIdentifier?.lowercased() else { return }
        for macro in running where macro.bundleId.lowercased() == quitBundle {
            stop(macroId: macro.id, reason: "目标 app 已退出")
        }
    }
}
