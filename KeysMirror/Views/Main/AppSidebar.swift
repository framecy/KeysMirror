import AppKit
import SwiftUI

/// 应用侧栏：图标（未运行时去饱和）+ 名称 + 映射/宏数量 + 启用状态点。
struct AppSidebar: View {
    @ObservedObject var store: MappingStore
    @ObservedObject var model: MainWindowModel

    /// bundleId → 正在运行的应用（图标 / 是否在运行）
    @State private var runningApps: [String: RunningApplication] = [:]
    @State private var hoveredProfileID: UUID?

    var body: some View {
        // spacing 0：原来 8pt 的间距 + List 自带的底部留白，在列表和 +/− 之间留出一条空白带
        VStack(alignment: .leading, spacing: 0) {
            if store.profiles.isEmpty {
                EmptyStateView(
                    title: "还没有应用配置",
                    systemImage: "keyboard.badge.eye",
                    description: "先添加一个正在运行的应用，再为它录制按键和点击位置。",
                    actionTitle: "添加应用",
                    action: { model.showAppPicker = true }
                )
            } else {
                // 不用 List 的 selection：系统会自己画一条通栏蓝，和自绘的圆角选中底叠成双层高亮。
                // 改成 ScrollView + 自绘行，选中态完全由我们控制。
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.profiles) { profile in
                            row(profile)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedProfileID = profile.id }
                                .contextMenu {
                                    Button(profile.isEnabled ? "禁用" : "启用") { toggleEnabled(profile) }
                                    Divider()
                                    Button("删除配置…", role: .destructive) {
                                        model.pendingProfileDeletion = profile
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.sm)
                }

                // 侧栏底部工具条：macOS 上「给侧栏列表加一项」的标准位置，
                // 位置固定，不会像 toolbar 那样随侧栏折叠而重排。
                Spacer(minLength: 0)
                Divider()
                HStack(spacing: 2) {
                    IconButton(systemName: "plus", help: "添加正在运行的应用") {
                        model.showAppPicker = true
                    }
                    IconButton(systemName: "minus", help: "删除选中的配置", role: .destructive) {
                        if let profile = store.profiles.first(where: { $0.id == model.selectedProfileID }) {
                            model.pendingProfileDeletion = profile
                        }
                    }
                    .disabled(model.selectedProfileID == nil)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.vertical, 2)
            }
        }
        .task { refreshRunningApps() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWorkspace.didLaunchApplicationNotification).receive(on: RunLoop.main)
        ) { _ in refreshRunningApps() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification).receive(on: RunLoop.main)
        ) { _ in refreshRunningApps() }
    }

    private func row(_ profile: AppProfile) -> some View {
        let running = runningApps[profile.bundleIdentifier.lowercased()]
        let icon = AppResolver.shared.icon(forBundleIdentifier: profile.bundleIdentifier)
        let isSelected = model.selectedProfileID == profile.id
        return HStack(spacing: Theme.Spacing.sm) {
            iconView(icon, isRunning: running != nil)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.appName)
                    .font(Theme.Typography.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                Text(running == nil ? "未运行" : "\(profile.mappings.count) 映射 · \(profile.macros.count) 宏")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(subtitleStyle(isSelected: isSelected, isRunning: running != nil))
            }
            Spacer(minLength: 2)
            StatusDot(state: profile.isEnabled ? .enabled : .disabled, size: Theme.Metrics.statusDotSize)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(minHeight: Theme.Metrics.listRowMinHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(rowBackground(isSelected: isSelected, isHovering: hoveredProfileID == profile.id))
        )
        .onHover { hoveredProfileID = $0 ? profile.id : (hoveredProfileID == profile.id ? nil : hoveredProfileID) }
    }

    /// 选中 = 实心 accent（macOS 侧栏惯例）；hover = 浅灰；其余透明。
    /// 只有一层背景，不再叠系统高亮。
    private func rowBackground(isSelected: Bool, isHovering: Bool) -> Color {
        if isSelected { return Theme.Palette.accent }
        if isHovering { return Theme.Palette.tint(.gray) }
        return .clear
    }

    /// 选中态下副标题压在实色 accent 上，用半透明白；未运行仍要显眼但不能是橙配蓝
    private func subtitleStyle(isSelected: Bool, isRunning: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white.opacity(isRunning ? 0.75 : 0.95)) }
        return isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.Palette.warning)
    }

    /// 已配置的应用一律显示自己的图标；未运行时去饱和 + 压低透明度，
    /// 既能一眼认出是哪个 app，又能看出它没在跑。
    @ViewBuilder
    private func iconView(_ image: NSImage?, isRunning: Bool) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
                .saturation(isRunning ? 1 : 0)
                .opacity(isRunning ? 1 : 0.55)
        } else {
            // 应用已被卸载 / 找不到 bundle
            Image(systemName: "questionmark.app.dashed")
                .frame(width: 22, height: 22)
                .foregroundStyle(.tertiary)
        }
    }

    private func toggleEnabled(_ profile: AppProfile) {
        var updated = profile
        updated.isEnabled.toggle()
        UndoCoordinator.shared.perform(
            name: updated.isEnabled ? "启用配置" : "禁用配置",
            do: { store.updateProfile(updated) },
            undo: { store.updateProfile(profile) }
        )
    }

    private func refreshRunningApps() {
        // 按 profile 逐个查未过滤的运行状态——不能复用 runningApplications()，
        // 它按 activationPolicy == .regular 过滤是为了给「添加应用」选择器排除后台进程，
        // 但会把没有标准菜单栏/Dock 的 iOS-on-Mac 游戏误判为「未运行」。
        runningApps = store.profiles.reduce(into: [:]) { result, profile in
            let key = profile.bundleIdentifier.lowercased()
            guard result[key] == nil else { return }
            result[key] = AppResolver.shared.runningApplicationInfo(bundleIdentifier: profile.bundleIdentifier)
        }
    }
}
