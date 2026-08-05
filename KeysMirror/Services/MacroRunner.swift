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
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)
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
        // 目标 app 不再需要在前台——session 层事件按「光标位置下的窗口」路由，
        // 实测（问道 / 阴阳师）游戏在后台也能收到点击且不会抢走焦点，
        // 因此宏可以在窗口平铺、用户操作别的 app 时继续跑。这里只要求进程还活着。
        guard let targetApp = AppResolver.shared.runningApplication(bundleIdentifier: bundleId) else {
            stop(macroId: macro.id, reason: "目标 app 已退出")
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

        // 安全网 2：目标必须真的露在最上层。宏不再要求前台，用户随时可能把别的窗口拖到
        // 游戏上面——session 层点击会直接打进那个窗口（浏览器的发送、编辑器的删除都可能被点到）。
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

        // ClickSimulator 内部走串行队列，连续调用天然依次投递，无需额外间隔
        for _ in 0..<clickCount {
            // 宏可能在用户操作别的 app 时后台执行，投递期间屏蔽物理鼠标，
            // 避免用户手上的鼠标移动把这一击挤掉
            ClickSimulator.shared.leftClick(at: clickPoint, targetApp: targetApp, suppressLocalInput: true, tagTargetProcess: true)
        }
        StatusBarController.shared.flashActivity()
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
