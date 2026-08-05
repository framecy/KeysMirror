import AppKit
import SwiftUI

/// 诊断窗（⌘⇧D）：触发记录 + 运行日志。
/// 它们是调试面板，从主窗 tab 移到独立窗口，把配置首屏让出来。
@MainActor
final class DiagnosticsWindowController {
    static let shared = DiagnosticsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            w.title = "KeysMirror 诊断"
            w.center()
            w.contentView = NSHostingView(rootView: DiagnosticsWindow())
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window?.orderOut(nil) }
}

struct DiagnosticsWindow: View {
    @StateObject private var logger = AppLogger.shared
    @StateObject private var store = MappingStore.shared
    @State private var tab: Tab = .triggers
    @State private var exportAlert: ImportAlert?
    @State private var experimentTargetID: UUID?

    enum Tab: String, CaseIterable, Identifiable {
        case triggers, logs, experiments
        var id: String { rawValue }
        var title: String {
            switch self {
            case .triggers: return "触发记录"
            case .logs: return "运行日志"
            case .experiments: return "实验"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SegmentedTabs(
                titles: Tab.allCases.map(\.title),
                selectedIndex: Tab.allCases.firstIndex(of: tab) ?? 0,
                onSelect: { tab = Tab.allCases[$0] }
            )

            switch tab {
            case .triggers: triggersTab
            case .logs: logsTab
            case .experiments: experimentsTab
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(minWidth: 640, minHeight: 420)
        .toastHost()
        .alert(item: $exportAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }

    private var triggersTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "最近 100 次成功触发", subtitle: "按时间倒序") {
                Button("清空") { logger.clearTriggerRecords() }
                                        .disabled(logger.triggerRecords.isEmpty)
            }

            if logger.triggerRecords.isEmpty {
                EmptyStateView(
                    title: "还没有触发记录",
                    systemImage: "bolt.circle",
                    description: "在目标应用里按下已配置的触发键，点击就会出现在这里。"
                )
            } else {
                List(logger.triggerRecords) { record in
                    HStack(spacing: Theme.Spacing.md) {
                        Text(Self.timeFormatter.string(from: record.timestamp))
                            .font(Theme.Typography.mono)
                            .foregroundStyle(.tertiary)
                            .frame(width: 88, alignment: .leading)
                        Text(record.trigger)
                            .font(Theme.Typography.mono)
                            .padding(.horizontal, Theme.Spacing.xs)
                            .padding(.vertical, 2)
                            .background(Theme.Palette.keyCapFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        Image(systemName: "arrow.right").font(Theme.Typography.body).foregroundStyle(.tertiary)
                        Text(record.mappingLabel)
                        Spacer()
                        if record.throttled {
                            Badge(text: "节流", color: Theme.Palette.warning)
                        }
                        Text("(\(Int(record.clickPoint.x)), \(Int(record.clickPoint.y)))")
                            .font(Theme.Typography.mono)
                            .foregroundStyle(.secondary)
                        if record.blockInput {
                            Image(systemName: "shield.lefthalf.filled")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.accent)
                                .help("已拦截原始按键")
                        }
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.inset)
            }
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "运行日志", subtitle: "INFO / WARN / ERROR / TRACE / ACTION") {
                HStack(spacing: Theme.Spacing.sm) {
                    Button("导出") { exportLogs() }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([logger.currentLogFileURL])
                    }
                    Button("清空") { logger.clear() }
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(logger.logs.enumerated()), id: \.offset) { _, log in
                        Text(log)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(LogStyle.color(for: log))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Theme.Spacing.sm)
            }
            .frame(maxHeight: .infinity)
            .background(Theme.Palette.tint(.gray), in: RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
    }

    // MARK: - 实验

    /// postToPid 实机验证面板。
    /// 目的：确认苹果官方「为 iPad 设计」运行时是否接受 `CGEventPostToPid`。
    /// 若接受，则指针闪烁与「宏必须前台」两个限制可一并解除（详见 Preferences 中的注释）。
    private var experimentsTab: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title: "点击投递诊断", subtitle: "验证点击能否送达、焦点是否被抢")

            Text("测试点击")
                .font(Theme.Typography.label)
            Text("向目标窗口中心发送一次点击，并自动记录点击前后的前台 app——"
                 + "「焦点是否被抢」由日志判定，不靠肉眼看窗口明暗（游戏取消暂停也会变亮，容易误判）。\n"
                 + "「延迟 3 秒」是更真实的场景：点完立刻切到你平时用的 app（浏览器/编辑器），"
                 + "让点击在你正操作别的窗口时触发。\n"
                 + "注意这是真实点击，会作用到游戏里，请先确认窗口中心不是危险操作位。")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.sm) {
                Picker("目标", selection: $experimentTargetID) {
                    Text("请选择").tag(UUID?.none)
                    ForEach(store.profiles) { profile in
                        Text(profile.appName).tag(UUID?.some(profile.id))
                    }
                }
                .frame(maxWidth: 260)

                Button("立即发送") { sendTestClick(afterDelay: 0) }
                    .disabled(experimentTargetID == nil)
                Button("延迟 3 秒发送") { sendTestClick(afterDelay: 3) }
                    .disabled(experimentTargetID == nil)
            }

            Text("结果看「运行日志」标签页。")
                .font(Theme.Typography.caption)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
    }

    private func sendTestClick(afterDelay delay: TimeInterval) {
        guard let id = experimentTargetID,
              let profile = store.profiles.first(where: { $0.id == id }) else { return }

        guard delay > 0 else {
            performTestClick(profile: profile)
            return
        }

        ToastCenter.shared.success("\(Int(delay)) 秒后发送——现在切到你平时用的 app")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            performTestClick(profile: profile)
        }
    }

    /// 发一次测试点击，并在点击前后各采一次前台 app 做对比。
    /// 焦点是否被抢是「平铺后台跑宏」可不可用的决定性因素，必须客观判定：
    /// 游戏窗口从暗变亮既可能是被激活，也可能只是自己取消了暂停，肉眼区分不了。
    private func performTestClick(profile: AppProfile) {
        guard let app = AppResolver.shared.runningApplication(bundleIdentifier: profile.bundleIdentifier) else {
            ToastCenter.shared.failure("\(profile.appName) 未在运行")
            return
        }
        guard let frame = WindowLocator.shared.focusedWindowFrame(for: profile.bundleIdentifier) else {
            ToastCenter.shared.failure("读不到 \(profile.appName) 的窗口位置")
            return
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let before = NSWorkspace.shared.frontmostApplication
        AppLogger.shared.log(
            "【实验】点击前 前台=\(before?.localizedName ?? "?") | 目标 \(profile.appName) "
            + "窗口 \(Int(frame.width))x\(Int(frame.height)) 中心 (\(Int(center.x)),\(Int(center.y)))",
            type: "ACTION"
        )

        ClickSimulator.shared.leftClick(at: center, targetApp: app)

        // 激活是异步的，等一拍再采样，否则会读到点击前的旧值
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let after = NSWorkspace.shared.frontmostApplication
            let stolen = after?.bundleIdentifier != before?.bundleIdentifier
            AppLogger.shared.log(
                "【实验】点击后 前台=\(after?.localizedName ?? "?") → "
                + (stolen ? "⚠️ 焦点被抢走（平铺跑宏不可用）" : "✅ 焦点未变（平铺跑宏可行）"),
                type: "ACTION"
            )
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = "导出 KeysMirror 日志"
        panel.nameFieldStringValue = "KeysMirror-log-\(Self.filenameFormatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logger.exportSnapshot().write(to: url, options: .atomic)
            ToastCenter.shared.success("日志已导出到 \(url.lastPathComponent)")
        } catch {
            exportAlert = ImportAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let filenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

/// 日志级别着色，HUD 与诊断窗共用。
enum LogStyle {
    static func color(for line: String) -> Color {
        if line.contains("[ERROR]") { return Theme.Palette.danger }
        if line.contains("[WARN]") { return Theme.Palette.warning }
        if line.contains("[ACTION]") { return .primary }
        return .secondary
    }

    /// 游戏内 HUD 默认只显示动作与告警，TRACE/INFO 太吵会刷屏。
    static func isActionOrProblem(_ line: String) -> Bool {
        line.contains("[ACTION]") || line.contains("[WARN]") || line.contains("[ERROR]")
    }
}
