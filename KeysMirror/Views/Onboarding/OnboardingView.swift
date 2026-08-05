import AppKit
import SwiftUI

/// 首次运行引导：授权 → 添加应用 → 录制第一条映射。
/// 仅首次显示；之后可从菜单栏面板重新打开。
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()

    private static let seenKey = "KeysMirror.hasSeenOnboarding"
    private var window: NSWindow?

    var hasSeen: Bool {
        UserDefaults.standard.bool(forKey: Self.seenKey)
    }

    func showIfNeeded() {
        guard !hasSeen else { return }
        show()
    }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.isReleasedWhenClosed = false
            w.title = "欢迎使用 KeysMirror"
            w.center()
            w.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in
                UserDefaults.standard.set(true, forKey: Self.seenKey)
                self?.window?.close()
                self?.window = nil
            }))
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @StateObject private var permissionChecker = PermissionChecker.shared
    @StateObject private var store = MappingStore.shared
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [Step] {
        [
            Step(
                title: "授予辅助功能权限",
                detail: "KeysMirror 需要这项权限才能拦截按键并模拟点击。授权后回到这里继续。",
                systemImage: "lock.shield",
                actionTitle: permissionChecker.isAccessibilityGranted ? nil : "去授权",
                action: { PermissionChecker.shared.requestAccessibilityPermission() },
                isDone: permissionChecker.isAccessibilityGranted
            ),
            Step(
                title: "添加一个应用",
                detail: "选择正在运行的目标应用（比如 PlayCover 里的游戏），映射与宏都按应用分开保存。",
                systemImage: "app.badge.plus",
                actionTitle: "打开配置窗口",
                action: { ConfigurationWindowController.shared.show() },
                isDone: !store.profiles.isEmpty
            ),
            Step(
                title: "录制第一条映射",
                detail: "在配置窗口点「新建映射」→ 录制触发键 → 录制点击位置。之后在游戏里按这个键，就会点到那个位置。",
                systemImage: "scope",
                actionTitle: nil,
                action: {},
                isDone: store.profiles.contains { !$0.mappings.isEmpty || !$0.macros.isEmpty }
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("三步开始使用")
                .font(Theme.Typography.title)

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, s in
                    stepCard(index: index, step: s)
                }
            }

            Spacer()

            HStack {
                Button("跳过") { onFinish() }
                Spacer()
                Button("开始使用") { onFinish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560, height: 420)
        .onAppear { permissionChecker.refreshStatus() }
    }

    private func stepCard(index: Int, step s: Step) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: s.isDone ? "checkmark.circle.fill" : s.systemImage)
                .font(.system(size: 22))
                .foregroundStyle(s.isDone ? Theme.Palette.success : Theme.Palette.accent)
                .frame(width: 28)
                .animation(Theme.Motion.standard(reduceMotion), value: s.isDone)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1). \(s.title)")
                    .font(Theme.Typography.section)
                Text(s.detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Spacing.sm)

            if let title = s.actionTitle, !s.isDone {
                Button(title, action: s.action)
                                }
        }
        .padding(Theme.Spacing.md)
        .cardSurface()
    }

    struct Step {
        let title: String
        let detail: String
        let systemImage: String
        let actionTitle: String?
        let action: () -> Void
        let isDone: Bool
    }
}
