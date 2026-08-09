import AppKit
import SwiftUI

/// 菜单栏弹出面板（左键点击图标）。右键仍然出 `NSMenu` 作为降级路径，
/// 保证键盘导航与无障碍不退化。
struct MenuBarPanel: View {
    @ObservedObject var store: MappingStore
    @ObservedObject var macroRunner: MacroRunner
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var permissionChecker: PermissionChecker

    let interceptorEnabled: Bool
    let frontBundleId: String?
    let onToggleInterceptor: () -> Void
    let onOpenConfiguration: () -> Void
    let onOpenDiagnostics: () -> Void
    let onOpenPermissions: () -> Void
    let onQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header

            if !permissionChecker.isAccessibilityGranted {
                Button {
                    PermissionChecker.shared.requestAccessibilityPermission()
                } label: {
                    Label("需要辅助功能权限，点此授权", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }
                .buttonStyle(.plain)
            }

            Divider()

            frontAppCard

            if let profile = frontProfile, !profile.macros.isEmpty {
                Divider()
                macroList(profile)
            }

            Divider()
            footer
        }
        .padding(Theme.Spacing.md)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Toggle("", isOn: Binding(get: { interceptorEnabled }, set: { _ in onToggleInterceptor() }))
                .toggleStyle(.switch)
                                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(interceptorEnabled ? "映射启用中" : "映射已禁用")
                    .font(Theme.Typography.section)
                if let hotkey = preferences.preferences.globalToggleHotkey {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("全局开关").font(Theme.Typography.caption).foregroundStyle(.secondary)
                        KeyCapView(trigger: .keyboard(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers))
                    }
                }
            }
            Spacer()
        }
    }

    private var frontAppCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("当前应用").font(Theme.Typography.caption).foregroundStyle(.secondary)
            if let profile = frontProfile {
                HStack(spacing: Theme.Spacing.sm) {
                    StatusDot(state: profile.isEnabled ? .enabled : .disabled, size: Theme.Metrics.statusDotSize)
                    Text(profile.appName).font(Theme.Typography.label).lineLimit(1)
                    Spacer()
                    Text("映射 \(profile.mappings.count) · 宏 \(profile.macros.count)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                HStack {
                    Text(frontAppName ?? "未知应用")
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("添加配置") { onOpenConfiguration() }
                                        }
            }
        }
    }

    private func macroList(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("宏").font(Theme.Typography.caption).foregroundStyle(.secondary)
            ForEach(profile.macros) { macro in
                HStack(spacing: Theme.Spacing.sm) {
                    StatusDot(
                        state: macroRunner.isRunning(macro.id) ? .running : (macro.isEnabled ? .enabled : .disabled),
                        size: Theme.Metrics.statusDotSize
                    )
                    Text(macro.label).font(Theme.Typography.body).lineLimit(1)
                    // 触发键：从这里能直接看到该按哪个键，不必回主窗查
                    Text(macro.displayShortcut)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Theme.Palette.keyCapFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Spacer()
                    if let running = macroRunner.running.first(where: { $0.id == macro.id }) {
                        Text(MacroMarqueeView.progressText(iteration: running.iteration, total: running.total))
                            .font(Theme.Typography.mono)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    IconButton(
                        systemName: macroRunner.isRunning(macro.id) ? "stop.fill" : "play.fill",
                        help: macroRunner.isRunning(macro.id) ? "停止" : "运行"
                    ) {
                        macroRunner.toggle(macro, profile: profile)
                    }
                    .disabled(!macro.isEnabled)
                }
            }
        }
        .animation(Theme.Motion.standard(reduceMotion), value: macroRunner.running)
    }

    /// 入口做成卡片网格：整块都是点击区（原来的一行文字命中区域太小，容易点空）
    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                PanelActionCard(title: "配置", systemImage: "slider.horizontal.3", action: onOpenConfiguration)
                PanelActionCard(title: "诊断", systemImage: "stethoscope", action: onOpenDiagnostics)
                PanelActionCard(title: "权限", systemImage: "lock.shield", action: onOpenPermissions)
            }
            HStack(spacing: Theme.Spacing.sm) {
                PanelActionCard(title: "引导", systemImage: "sparkles", action: { OnboardingController.shared.show() })
                PanelActionCard(title: "日志目录", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.currentLogFileURL])
                }
                PanelActionCard(title: "退出", systemImage: "power", role: .destructive, action: onQuit)
            }

            Divider()

            // 两行设置统一成「标签靠左、控件靠右」的系统设置行样式。
            // 直接用 Toggle / Picker 自带的标签会按内容宽度居中，两行左边缘对不齐，
            // 挤在一起看着像没对齐——所以标签拆出来自己排，控件 labelsHidden。
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 与主窗「设置 → 在 Dock 中显示」共用同一个偏好字段，两处状态天然同步
                HStack {
                    Text("在 Dock 中显示").font(Theme.Typography.body)
                    Spacer(minLength: Theme.Spacing.sm)
                    Toggle("", isOn: Binding(
                        get: { preferences.preferences.showInDock },
                        set: { newValue in
                            preferences.update { $0.showInDock = newValue }
                            preferences.applyDockVisibility()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                // 同样与主窗设置菜单共用同一个偏好字段。放在菜单栏是因为这个选择和
                // 「我现在要不要挂机」强相关——用户往往是宏跑起来之后才想改它。
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("后台宏策略").font(Theme.Typography.body)
                        Spacer(minLength: Theme.Spacing.sm)
                        Picker("", selection: Binding(
                            get: { preferences.preferences.backgroundMacroPolicy },
                            set: { newValue in preferences.update { $0.backgroundMacroPolicy = newValue } }
                        )) {
                            ForEach(BackgroundMacroPolicy.allCases, id: \.self) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    // 说明文字跟着选项变：用户不用点开就知道当前这档意味着什么
                    Text(preferences.preferences.backgroundMacroPolicy.detail)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var frontProfile: AppProfile? {
        guard let frontBundleId else { return nil }
        return store.profiles.first { $0.bundleIdentifier.lowercased() == frontBundleId.lowercased() }
    }

    private var frontAppName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }
}
