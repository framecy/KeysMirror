import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// `MacroRunner.runningMacroId` 变化时广播；StatusBarController 据此更新菜单栏。
    static let macroRunStateDidChange = Notification.Name("KeysMirror.MacroRunStateDidChange")
}

/// 串行执行单个宏：同一时刻只允许一个宏在运行。
/// 取消通过 `Task.cancel()` 实现，长 sleep 也会立即结束。
@MainActor
final class MacroRunner: ObservableObject {
    static let shared = MacroRunner()

    @Published private(set) var runningMacroId: UUID?
    @Published private(set) var runningMacroLabel: String?
    @Published private(set) var runningBundleId: String?

    private var task: Task<Void, Never>?
    private let logger = AppLogger.shared

    private init() {
        // 前台 app 切换时如果离开了宏所属的 app，自动停止
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleFrontAppChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// 同 macro 再按 → 停；不同 → 停旧启新；空闲 → 启动。
    func toggle(_ macro: MacroAction, profile: AppProfile) {
        if let runningId = runningMacroId, runningId == macro.id {
            stop(reason: "用户再按触发键")
            return
        }
        startInternal(macro, profile: profile)
    }

    func stop(reason: String? = nil) {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        if let label = runningMacroLabel {
            logger.log("【宏停止】\(label)\(reason.map { "（\($0)）" } ?? "")", type: "ACTION")
        }
        runningMacroId = nil
        runningMacroLabel = nil
        runningBundleId = nil
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

    // MARK: - Internal

    private func startInternal(_ macro: MacroAction, profile: AppProfile) {
        if task != nil { stop(reason: "切换到新宏") }

        guard !macro.steps.isEmpty else {
            logger.log("宏 [\(macro.label)] 没有步骤，不执行", type: "WARN")
            return
        }

        runningMacroId = macro.id
        runningMacroLabel = macro.label
        runningBundleId = profile.bundleIdentifier
        NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)

        let totalIterations = Self.computeStepCount(repeatCount: macro.repeatCount)
        let captured = macro
        let bundleId = profile.bundleIdentifier
        let appName = profile.appName

        logger.log("【宏启动】\(captured.label) | \(captured.steps.count) 步 × \(captured.repeatCount == 0 ? "无限" : "\(totalIterations)") 次 | \(appName)", type: "ACTION")

        task = Task { [weak self] in
            await self?.run(macro: captured, totalIterations: totalIterations, bundleId: bundleId)
        }
    }

    private func run(macro: MacroAction, totalIterations: Int, bundleId: String) async {
        for iteration in 0..<totalIterations {
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
                    iteration: iteration,
                    totalIterations: totalIterations,
                    macro: macro,
                    bundleId: bundleId
                )
            }
        }

        // 自然结束
        await MainActor.run {
            if self.runningMacroId == macro.id {
                self.logger.log("【宏完成】\(macro.label)（执行 \(totalIterations) 次）", type: "ACTION")
                self.runningMacroId = nil
                self.runningMacroLabel = nil
                self.runningBundleId = nil
                self.task = nil
                NotificationCenter.default.post(name: .macroRunStateDidChange, object: self)
            }
        }
    }

    private func fireStep(
        _ step: MacroStep,
        stepIndex: Int,
        iteration: Int,
        totalIterations: Int,
        macro: MacroAction,
        bundleId: String
    ) {
        // 前台 app 切走 → 静默停
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier?.lowercased() == bundleId.lowercased() else {
            stop(reason: "目标 app 不在前台")
            return
        }

        guard let windowFrame = WindowLocator.shared.focusedWindowFrame(for: bundleId) else {
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

        let clickPoint = CoordinateConverter.absolutePoint(
            relativeX: resolvedOffset.x,
            relativeY: resolvedOffset.y,
            in: windowFrame
        )

        // 安全网：点击点必须落在窗口内（避免误唤后台 app）
        guard windowFrame.contains(clickPoint) else {
            logger.log("宏 [\(macro.label)] 第 \(stepIndex + 1) 步：点击点 (\(Int(clickPoint.x)),\(Int(clickPoint.y))) 落在窗口 \(Int(windowFrame.width))x\(Int(windowFrame.height)) 外，已跳过", type: "WARN")
            return
        }

        let iterText = totalIterations == Int.max ? "∞" : "\(iteration + 1)/\(totalIterations)"
        logger.log("【宏步骤】[\(macro.label)] \(iterText) - 第 \(stepIndex + 1)/\(macro.steps.count) 步 → 点击 (\(Int(clickPoint.x)),\(Int(clickPoint.y)))", type: "ACTION")

        ClickSimulator.shared.leftClick(at: clickPoint, targetApp: frontApp)
        StatusBarController.shared.flashActivity()
    }

    // MARK: - 前台变化

    @objc private func handleFrontAppChange(_ note: Notification) {
        guard let runningBundleId else { return }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased()
        if frontBundle != runningBundleId.lowercased() {
            stop(reason: "前台切走")
        }
    }
}
