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

    /// 连续 150ms 内没有新的后台点击，才认为这一阵子点完了，可以把前台还回去。
    /// 取这个值是因为最短的宏步间隔通常也在百毫秒量级；再短会让还原和下一步点击打架，
    /// 再长则用户会觉得「点完半天才切回来」。
    static let restoreDebounce: TimeInterval = 0.15

    /// 已经就「目标在后台被跳过」记过日志的宏。防止无限循环宏把日志刷屏。
    private var skipLoggedMacroIds: Set<UUID> = []

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
        if running.isEmpty { cancelPendingRestore() }
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
        cancelPendingRestore()
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)
    }

    /// 全部宏都停了就没有「还原前台」的语义了——挂起中的那次必须取消，
    /// 否则用户手动停完宏、自己切到别的窗口，150ms 后前台会被莫名其妙抢走。
    private func cancelPendingRestore() {
        pendingRestore?.cancel()
        pendingRestore = nil
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

                fireStep(
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
    ) {
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

        if !targetIsFront && policy == .frontmostOnly {
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
        if let occluder = WindowLocator.shared.occludingApp(at: clickPoint, ownedBy: targetApp.processIdentifier) {
            logger.log("宏 [\(macro.label)] 第 \(stepIndex + 1) 步：点击点 (\(Int(clickPoint.x)),\(Int(clickPoint.y))) 被「\(occluder)」遮挡，已跳过", type: "WARN")
            return
        }

        let iterText = totalIterations == Int.max ? "∞" : "\(iteration + 1)/\(totalIterations)"
        let driftText = step.driftPercent > 0 ? " 漂移\(String(format: "%.1f", step.driftPercent))%" : ""
        // 连击共用同一坐标（漂移只在进入本步时算一次），否则双击会被目标 app 拆成两次单击
        let clickCount = max(1, step.clickCount)
        let clickText = clickCount > 1 ? " ×\(clickCount)" : ""
        logger.log("【宏步骤】[\(macro.label)] \(iterText) - 第 \(stepIndex + 1)/\(macro.steps.count) 步\(driftText) → 点击 (\(Int(clickPoint.x)),\(Int(clickPoint.y)))\(clickText)", type: "ACTION")

        // ClickSimulator 内部走串行队列，连续调用天然依次投递，无需额外间隔。
        // 前台/后台的参数差异全部收敛在 `clickPlan` 里，便于单测锁死（见 MacroRunnerTests）。
        let plan = Self.clickPlan(targetIsFront: targetIsFront)
        // 真的点出去了 → 清掉「已就跳过记过日志」的标记，下次再被跳过时还会提示一次。
        skipLoggedMacroIds.remove(macro.id)
        let previousApp = frontApp
        for _ in 0..<clickCount {
            ClickSimulator.shared.leftClick(
                at: clickPoint,
                targetApp: targetApp,
                dwell: profile.clickDwellSeconds,
                suppressLocalInput: plan.suppressLocalInput,
                tagTargetProcess: plan.tagTargetProcess,
                completion: plan.restoresPreviousApp ? { [weak self] in
                    self?.scheduleFrontmostRestore(to: previousApp, target: targetApp)
                } : nil
            )
        }
        NotificationCenter.default.post(name: .inputActivityDidFire, object: nil)
    }

    /// 单次点击的投递参数。前台与后台的全部差异就这三个开关。
    struct ClickPlan: Equatable {
        /// 投递期间屏蔽物理鼠标事件。
        var suppressLocalInput: Bool
        /// 给 session 事件打目标进程标记（`movedBack` 靠它不广播给光标下的别的 app）。
        var tagTargetProcess: Bool
        /// 点完是否要把前台还给点击前那个 app。
        var restoresPreviousApp: Bool
    }

    /// 目标已在前台（用户边玩边跑宏 + 按键映射）：必须和 KeyInterceptor 走同一条路径——
    /// 不开 `suppressLocalInput`（否则宏步会吞掉玩家的物理鼠标，和映射叠在一起就是「鼠标闪/顿」），
    /// 也不还原前台（游戏本来就在前台，再 activate 等于每步重抢一次焦点，
    /// 表现成「宏把游戏窗口又激活了一遍」）。
    ///
    /// 目标在后台（用户显式选了「允许后台执行」）：session 投递会把窗口顶到前台，
    /// 只能点完再还原。此时才需要 suppress + tag。
    static func clickPlan(targetIsFront: Bool) -> ClickPlan {
        ClickPlan(
            suppressLocalInput: !targetIsFront,
            tagTargetProcess: !targetIsFront,
            restoresPreviousApp: !targetIsFront
        )
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
            guard !Task.isCancelled, self != nil else { return }
            // 只在目标确实还占着前台时才还原。用户在这段间隔里自己切走了 → 什么都别做，
            // 否则会把用户刚打开的窗口又抢掉。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid else { return }
            guard previousApp.isTerminated == false else { return }
            AppResolver.shared.activate(previousApp)
        }
    }

    /// 「跳过因为目标在后台」的日志节流：无限循环宏每轮都会走到这里，
    /// 不节流会把日志刷成一片。只在从「在跑」变成「被跳过」时说一次。
    private func logSkippedBecauseBackground(macro: MacroAction, frontAppName: String?) {
        guard !skipLoggedMacroIds.contains(macro.id) else { return }
        skipLoggedMacroIds.insert(macro.id)
        let front = frontAppName.map { "（当前前台：\($0)）" } ?? ""
        logger.log(
            "宏 [\(macro.label)] 目标不在前台，已跳过\(front)。切回目标窗口即自动继续；" +
            "要让它在后台也跑，去 设置 → 后台宏策略 改成「允许后台执行」。",
            type: "WARN"
        )
    }

    // MARK: - 前台变化

    @objc private func handleAppTerminated(_ note: Notification) {
        guard let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let quitBundle = quit.bundleIdentifier?.lowercased() else { return }
        for macro in running where macro.bundleId.lowercased() == quitBundle {
            stop(macroId: macro.id, reason: "目标 app 已退出")
        }
    }
}
