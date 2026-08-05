import SwiftUI

/// 主窗底部常驻状态条：权限 · 拦截器开关 · 最近一次触发。
/// 诊断入口已上移到右上角工具栏，与设置入口同级。
/// 权限缺失时整条变 warning 底色（取代旧的详情页顶部横幅）。
struct MainStatusBar: View {
    @ObservedObject var permissionChecker: PermissionChecker
    @ObservedObject var logger: AppLogger
    @ObservedObject var preferences: PreferencesStore
    let interceptorEnabled: Bool
    let onToggleInterceptor: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if permissionChecker.isAccessibilityGranted {
                Label("辅助功能已授权", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(Theme.Palette.success)
            } else {
                Label("需要辅助功能权限", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.warning)
                Button("去授权") { PermissionChecker.shared.requestAccessibilityPermission() }
                    .buttonStyle(.borderedProminent)
            }

            Divider().frame(height: Theme.Metrics.dividerHeight)

            Button(action: onToggleInterceptor) {
                HStack(spacing: Theme.Spacing.xs) {
                    StatusDot(state: interceptorEnabled ? .enabled : .disabled, size: Theme.Metrics.statusDotSize)
                    Text(interceptorEnabled ? "映射启用中" : "映射已禁用")
                    if let hotkey = preferences.preferences.globalToggleHotkey {
                        KeyCapView(trigger: .keyboard(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers))
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(height: Theme.Metrics.minHitTarget)
            .contentShape(Rectangle())
            .help("点击切换；也可以按全局快捷键")

            Divider().frame(height: Theme.Metrics.dividerHeight)

            if let latest = logger.triggerRecords.first {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("最近触发")
                        .foregroundStyle(.secondary)
                    Text(latest.trigger)
                        .font(Theme.Typography.mono)
                    Image(systemName: "arrow.right").font(Theme.Typography.body).foregroundStyle(.tertiary)
                    Text(latest.mappingLabel).lineLimit(1)
                }
                .transition(.opacity)
                .id(latest.id)
            }
            // 没有触发记录时留空：用一整行说「什么都没有」是纯噪音

            Spacer()

            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        .font(Theme.Typography.body)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: 40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            permissionChecker.isAccessibilityGranted
                ? AnyShapeStyle(Theme.Palette.panel)
                : AnyShapeStyle(Theme.Palette.tint(Theme.Palette.warning))
        )
        .animation(Theme.Motion.standard(reduceMotion), value: permissionChecker.isAccessibilityGranted)
        .animation(Theme.Motion.standard(reduceMotion), value: logger.triggerRecords.first?.id)
    }
}
