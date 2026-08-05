import AppKit
import SwiftUI

/// 录制会话：把「隐藏主窗 → 前台化目标 app → 显示 HUD 与目标窗描边 → 结束后恢复主窗」
/// 这套流程收敛到一处，供映射点位录制、宏序列录制共用。
/// 见 docs/UI-Redesign.md 6.4。
@MainActor
final class RecordingSession {
    static let shared = RecordingSession()

    private(set) var isActive = false
    private var bundleIdentifier: String?

    private init() {}

    func begin(
        profile: AppProfile,
        title: String,
        subtitle: String,
        targetApp: NSRunningApplication,
        showsClickCount: Bool = false
    ) {
        isActive = true
        bundleIdentifier = profile.bundleIdentifier

        RecordingHUDController.shared.show(title: title, subtitle: subtitle, showsClickCount: showsClickCount)
        TargetWindowHighlight.shared.show(bundleIdentifier: profile.bundleIdentifier)

        ConfigurationWindowController.shared.hide()
        // 只让当前正在操作的那扇宏编辑窗让位，其余开着的宏窗口不动（见 A2 修复说明）
        MacroEditorWindowController.shared.hideForRecording()
        targetApp.unhide()

        // 不再调用 NSApp.deactivate()，也不再延迟发起激活请求。
        //
        // 这里之前的写法是「先 NSApp.deactivate() 把自己切到后台，隔 0.15s 再请求激活目标」，
        // 理由是「紧挨着 deactivate() 调用会被系统合并掉」——这个假设是错的，而且是反的：
        // `NSRunningApplication.activate(from:options:)`（macOS 14+ 的现行 API）要求
        // `from:` 参数（这里传 `.current`，也就是本 App）在发起请求的那一刻仍然是「活跃」的，
        // 系统才会信任这次请求；先手动 deactivate() 自己，等于在请求发出前就让 `.current`
        // 失去了发起激活的资格，请求被系统悄悄丢弃——表现正是「点了录制但游戏没切过来」。
        // 而结束录制时又要把自己的窗口拉回前台、重新变成 key window，这一路径上激活状态
        // 本就是错的，会连带导致宏窗口拿不回真正的输入焦点（点不动、编辑不了、存不了）。
        //
        // 现在的策略：不主动碰自己的激活状态，直接、立即请求激活目标——`targetApp.activate(...)`
        // 本身就会把它的窗口带到最前、间接让我们让位，不需要额外一步自我降级。
        activateTarget(bundleIdentifier: profile.bundleIdentifier, retryCount: 6)
    }

    /// 结束录制：收起 HUD / 描边并把主窗带回来。
    func end(restoreWindow: Bool = true) {
        guard isActive else { return }
        isActive = false
        bundleIdentifier = nil

        RecordingHUDController.shared.hide()
        TargetWindowHighlight.shared.hide()

        guard restoreWindow else { return }
        NSApp.unhide(nil)
        ConfigurationWindowController.shared.show()
        MacroEditorWindowController.shared.restoreFromRecording()
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateClickCount(_ count: Int) {
        RecordingHUDController.shared.updateClickCount(count)
    }

    /// 点击落在目标窗口之外：HUD 抖一下并提示，录制继续。
    func rejectOutOfBounds(appName: String) {
        RecordingHUDController.shared.rejectClick(hint: "点在 \(appName) 窗口内才会被记录")
    }

    /// 重试到目标真的成为前台为止：`activate` 返回 true 只代表请求已发出。
    private func activateTarget(bundleIdentifier: String, retryCount: Int) {
        guard retryCount > 0, isActive else { return }

        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier?.lowercased() == bundleIdentifier.lowercased() {
            return
        }
        AppResolver.shared.activate(bundleIdentifier: bundleIdentifier)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.activateTarget(bundleIdentifier: bundleIdentifier, retryCount: retryCount - 1)
        }
    }
}
