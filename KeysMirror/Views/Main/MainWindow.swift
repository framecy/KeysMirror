import AppKit
import SwiftUI

/// 主窗骨架：侧栏（应用）· 内容区（映射 / 宏 / 键位总览）· Inspector · 底部状态条。
/// 编辑一律走 Inspector 即时保存，不再有编辑 sheet（见 docs/UI-Redesign.md 6.1–6.3）。
struct MainWindow: View {
    @StateObject private var store = MappingStore.shared
    @StateObject private var permissionChecker = PermissionChecker.shared
    @StateObject private var logger = AppLogger.shared
    @StateObject private var preferences = PreferencesStore.shared
    @StateObject private var macroRunner = MacroRunner.shared
    @StateObject private var model = MainWindowModel()
    @StateObject private var undo = UndoCoordinator.shared

    @State private var isRecordingGlobalHotkey = false
    @State private var isSettingsHovering = false
    @State private var isDiagnosticsHovering = false
    @State private var alert: ImportAlert?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // 自己画的头栏：位置绝对固定。
            // 不用 NavigationSplitView 的 toolbar——它会随侧栏折叠把按钮挪来挪去，
            // 而且系统自带的侧栏开关和自定义的面板开关长得几乎一样，容易看成两个同样的东西。
            windowHeader
            Divider()

            HStack(spacing: 0) {
                if model.sidebarVisible {
                    AppSidebar(store: store, model: model)
                        .frame(width: Theme.Metrics.sidebarWidth)
                        .background(Theme.Palette.panel)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let target = model.inspectorTarget, let profile = selectedProfile {
                    Divider()
                    inspector(target: target, profile: profile)
                        .frame(width: Theme.Metrics.inspectorWidth)
                        .background(Theme.Palette.panel)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Theme.Motion.standard(reduceMotion), value: model.sidebarVisible)
            .animation(Theme.Motion.standard(reduceMotion), value: model.inspectorTarget)

            Divider()

            MainStatusBar(
                permissionChecker: permissionChecker,
                logger: logger,
                preferences: preferences,
                interceptorEnabled: KeyInterceptor.shared.isEnabled,
                onToggleInterceptor: toggleInterceptor,
            )
        }
        .frame(minWidth: 1000, minHeight: 640)
        // 顶到标题栏：否则 NSHostingView 会避开安全区，自绘头栏下面还压着一条空白系统标题栏
        .ignoresSafeArea(.container, edges: .top)
        .toastHost()
        .sheet(isPresented: $model.showAppPicker) {
            AppPickerView { application in
                store.addProfile(bundleIdentifier: application.bundleIdentifier, appName: application.displayName)
                if let added = store.profiles.first(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                    model.selectedProfileID = added.id
                }
            }
        }
        .alert(item: $alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("好")))
        }
        .alert(item: $model.pendingProfileDeletion) { profile in
            Alert(
                title: Text("删除「\(profile.appName)」配置？"),
                message: Text("将同时删除 \(profile.mappings.count) 条映射和 \(profile.macros.count) 个宏，此操作可用 Toast 里的撤销恢复。"),
                primaryButton: .destructive(Text("删除")) { deleteProfile(profile) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onAppear {
            permissionChecker.refreshStatus()
            if model.selectedProfileID == nil {
                model.selectedProfileID = store.profiles.first?.id
            }
            undo.startMonitoring()
        }
        .onDisappear { undo.stopMonitoring() }
        .onChange(of: model.selectedProfileID) { _ in
            model.inspectorTarget = nil
        }
    }

    // MARK: - 头栏（固定位置，不随任何面板开合而移动）

    private var windowHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Spacer().frame(width: Theme.Metrics.trafficLightGutter)  // 让开左上角红绿灯

            IconButton(systemName: "sidebar.leading", help: model.sidebarVisible ? "隐藏应用列表" : "显示应用列表") {
                withAnimation(Theme.Motion.standard(reduceMotion)) { model.sidebarVisible.toggle() }
            }

            Text("KeysMirror")
                .font(Theme.Typography.title)
                .padding(.leading, Theme.Spacing.xs)

            Spacer()

            // 「添加应用」只保留侧栏底部那一个入口，这里重复了
            Button { DiagnosticsWindowController.shared.show() } label: {
                ToolbarIconLabel(systemName: "stethoscope", isHovering: isDiagnosticsHovering)
            }
            .buttonStyle(.plain)
            .onHover { isDiagnosticsHovering = $0 }
            .animation(Theme.Motion.quick(reduceMotion), value: isDiagnosticsHovering)
            .help("诊断（触发记录 / 日志）")

            Menu {
                Button(undo.undoActionName.map { "撤销\($0)" } ?? "撤销") { undo.undo() }
                    .disabled(!undo.canUndo)
                Button(undo.redoActionName.map { "重做\($0)" } ?? "重做") { undo.redo() }
                    .disabled(!undo.canRedo)
                Divider()
                Button("导出全部配置…") { exportAll() }
                    .disabled(store.profiles.isEmpty)
                Button("导入并合并…") { triggerImport(.merge) }
                Button("导入为新配置…") { triggerImport(.addAsNew) }
                Divider()
                Button("全局开关快捷键：\(globalHotkeyLabel)") { startRecordingGlobalHotkey() }
                if preferences.preferences.globalToggleHotkey != nil {
                    Button("清除全局快捷键") { applyHotkeyConfig(nil) }
                }
                Divider()
                Toggle("在 Dock 中显示", isOn: Binding(
                    get: { preferences.preferences.showInDock },
                    set: { newValue in
                        preferences.update { $0.showInDock = newValue }
                        preferences.applyDockVisibility()
                    }
                ))
                Divider()
                Button("使用引导") { OnboardingController.shared.show() }
            } label: {
                ToolbarIconLabel(systemName: "gearshape", isHovering: isSettingsHovering)
            }
            // .button + .plain：.borderlessButton 会强行改写标签配色，换成这组才留得住
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { isSettingsHovering = $0 }
            .animation(Theme.Motion.quick(reduceMotion), value: isSettingsHovering)
            .help("设置与更多操作")
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: Theme.Metrics.headerHeight)
        .background(Theme.Palette.panel)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                profileHeader(profile)

                HStack(spacing: Theme.Spacing.md) {
                    SegmentedTabs(
                        titles: ["映射 (\(profile.mappings.count))", "宏 (\(profile.macros.count))"],
                        selectedIndex: model.section == .mappings ? 0 : 1,
                        onSelect: { model.section = $0 == 0 ? .mappings : .macros }
                    )

                    SearchField(text: $model.searchText)
                        .frame(maxWidth: 240)

                    Spacer(minLength: 0)
                }

                switch model.section {
                case .mappings: mappingsSection(profile)
                case .macros: macrosSection(profile)
                }
            }
            .padding(Theme.Spacing.lg)
        } else {
            EmptyStateView(
                title: "请选择一个应用",
                systemImage: "cursorarrow.click",
                description: "在左侧选择应用后，才能管理它的按键映射与宏。",
                actionTitle: store.profiles.isEmpty ? "添加应用" : nil,
                action: store.profiles.isEmpty ? { model.showAppPicker = true } : nil
            )
        }
    }

    /// 当前配置的标题条：只放**与这个配置有关**的操作（启用开关 + 应用设置）。
    /// 全局操作（添加应用 / 导入导出 / 撤销…）一律在头栏，两处互不重复。
    private func profileHeader(_ profile: AppProfile) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.appName).font(Theme.Typography.title)
                Text(profile.bundleIdentifier)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Theme.Spacing.md)

            Toggle("启用", isOn: Binding(
                get: { profile.isEnabled },
                set: { newValue in
                    var updated = profile
                    updated.isEnabled = newValue
                    store.updateProfile(updated)
                }
            ))
            .toggleStyle(.switch)

            Menu {
                Toggle("显示位置指示器", isOn: Binding(
                    get: { profile.showOverlay },
                    set: { newValue in
                        var updated = profile
                        updated.showOverlay = newValue
                        store.updateProfile(updated)
                    }
                ))
                Divider()
                Button("导出此配置…") { exportProfile(profile) }
                Button("删除配置…", role: .destructive) { model.pendingProfileDeletion = profile }
            } label: {
                Label("应用设置", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(Theme.Spacing.md)
        .cardSurface()
    }

    private func mappingsSection(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "按键 → 点击的固定映射") {
                Button { model.startNewMapping() } label: { Label("新建映射", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
            }
            MappingListView(
                profile: profile,
                searchText: model.searchText,
                onEdit: { model.edit(mapping: $0) },
                onDelete: { deleteMapping($0, from: profile) },
                onToggleEnabled: { mapping in toggleMapping(mapping, in: profile) },
                onDuplicate: { duplicateMapping($0, in: profile) }
            )
        }
    }

    private func macrosSection(_ profile: AppProfile) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "一个触发键执行多步点击", subtitle: "每步独立延迟 / 连击 / 循环 N 次或无限") {
                Button { model.startNewMacro(profile: profile) } label: { Label("新建宏", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            MacroListView(
                profile: profile,
                runningMacroIds: Set(macroRunner.running.map(\.id)),
                searchText: model.searchText,
                onEdit: { model.edit(macro: $0, in: profile) },
                onDelete: { deleteMacro($0, from: profile) },
                onToggleEnabled: { macro in toggleMacro(macro, in: profile) },
                onDuplicate: { duplicateMacro($0, in: profile) }
            )
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(target: MainWindowModel.InspectorTarget, profile: AppProfile) -> some View {
        VStack(spacing: 0) {
            // Inspector 自己的关闭按钮：用 xmark 而不是 sidebar 图标——
            // 后者和标题栏里系统的侧栏开关几乎一模一样，是之前「两个侧边栏开关」的由来。
            HStack {
                Spacer()
                Button {
                    model.inspectorTarget = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("关闭（Esc）")
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.top, Theme.Spacing.sm)

            switch target {
            case .mapping(let id):
                MappingInspector(profile: profile, mapping: profile.mappings.first(where: { $0.id == id }))
                    .id(target.id)
            case .draftMapping:
                MappingInspector(profile: profile, mapping: nil)
                    .id(target.id)
            }
        }
    }

    // MARK: - 操作

    private var selectedProfile: AppProfile? {
        store.profiles.first(where: { $0.id == model.selectedProfileID })
    }

    private func toggleInterceptor() {
        (NSApp.delegate as? AppDelegate)?.toggleInterceptor()
    }

    private func deleteMapping(_ mapping: KeyMapping, from profile: AppProfile) {
        // 记住原位置，撤销时放回原处而不是追加到末尾
        let index = store.indexOfMapping(mapping, in: profile) ?? store.profiles.count
        undo.perform(
            name: "删除映射",
            do: {
                store.deleteMapping(mapping, from: profile)
                model.clearInspectorIfNeeded(deletedId: mapping.id)
            },
            undo: { store.insertMapping(mapping, at: index, in: profile) }
        )
        ToastCenter.shared.undoable("已删除映射「\(mapping.label)」") { undo.undo() }
    }

    private func deleteMacro(_ macro: MacroAction, from profile: AppProfile) {
        let index = store.indexOfMacro(macro, in: profile) ?? store.profiles.count
        undo.perform(
            name: "删除宏",
            do: {
                if macroRunner.isRunning(macro.id) { macroRunner.stop(macroId: macro.id, reason: "用户删除宏") }
                store.deleteMacro(macro, from: profile)
                model.clearInspectorIfNeeded(deletedId: macro.id)
            },
            undo: { store.insertMacro(macro, at: index, in: profile) }
        )
        ToastCenter.shared.undoable("已删除宏「\(macro.label)」") { undo.undo() }
    }

    private func deleteProfile(_ profile: AppProfile) {
        let index = store.indexOfProfile(profile) ?? store.profiles.count
        undo.perform(
            name: "删除配置",
            do: {
                store.deleteProfile(profile)
                if model.selectedProfileID == profile.id {
                    model.selectedProfileID = store.profiles.first?.id
                }
            },
            undo: {
                store.restoreProfile(profile, at: index)
                model.selectedProfileID = profile.id
            }
        )
        ToastCenter.shared.undoable("已删除配置「\(profile.appName)」") { undo.undo() }
    }

    private func toggleMapping(_ mapping: KeyMapping, in profile: AppProfile) {
        var updated = mapping
        updated.isEnabled.toggle()
        undo.perform(
            name: updated.isEnabled ? "启用映射" : "禁用映射",
            do: { store.updateMapping(updated, in: profile) },
            undo: { store.updateMapping(mapping, in: profile) }
        )
    }

    private func toggleMacro(_ macro: MacroAction, in profile: AppProfile) {
        var updated = macro
        updated.isEnabled.toggle()
        undo.perform(
            name: updated.isEnabled ? "启用宏" : "禁用宏",
            do: {
                if macroRunner.isRunning(macro.id) && macro.isEnabled {
                    macroRunner.stop(macroId: macro.id, reason: "用户禁用宏")
                }
                store.updateMacro(updated, in: profile)
            },
            undo: { store.updateMacro(macro, in: profile) }
        )
    }

    private func duplicateMapping(_ mapping: KeyMapping, in profile: AppProfile) {
        var copy = mapping
        copy = KeyMapping(
            id: UUID(),
            keyCode: mapping.keyCode,
            modifiers: mapping.modifiers,
            triggerType: mapping.triggerType,
            mouseButtonNumber: mapping.mouseButtonNumber,
            relativeX: mapping.relativeX,
            relativeY: mapping.relativeY,
            label: mapping.label + " 副本",
            blockInput: mapping.blockInput,
            referenceWidth: mapping.referenceWidth,
            referenceHeight: mapping.referenceHeight,
            isEnabled: false  // 触发器与原件相同，先禁用避免冲突，改键后再启用
        )
        undo.perform(
            name: "复制映射",
            do: {
                store.addMapping(copy, to: profile)
                model.edit(mapping: copy)
            },
            undo: {
                store.deleteMapping(copy, from: profile)
                model.clearInspectorIfNeeded(deletedId: copy.id)
            }
        )
        ToastCenter.shared.success("已复制映射，已先禁用以免与原触发键冲突")
    }

    private func duplicateMacro(_ macro: MacroAction, in profile: AppProfile) {
        let copy = MacroAction(
            id: UUID(),
            label: macro.label + " 副本",
            triggerType: macro.triggerType,
            keyCode: macro.keyCode,
            modifiers: macro.modifiers,
            mouseButtonNumber: macro.mouseButtonNumber,
            blockInput: macro.blockInput,
            isEnabled: false,
            repeatCount: macro.repeatCount,
            steps: macro.steps
        )
        undo.perform(
            name: "复制宏",
            do: {
                store.addMacro(copy, to: profile)
                model.edit(macro: copy, in: profile)
            },
            undo: {
                store.deleteMacro(copy, from: profile)
                model.clearInspectorIfNeeded(deletedId: copy.id)
            }
        )
        ToastCenter.shared.success("已复制宏，已先禁用以免与原触发键冲突")
    }

    // MARK: - 全局 hotkey

    private var globalHotkeyLabel: String {
        if isRecordingGlobalHotkey { return "等待按键…" }
        if let cfg = preferences.preferences.globalToggleHotkey {
            return CGKeyCodeNames.shortcutLabel(for: cfg.keyCode, modifiers: cfg.modifiers)
        }
        return "未设置"
    }

    private func startRecordingGlobalHotkey() {
        if isRecordingGlobalHotkey {
            TriggerRecorder.shared.stop()
            isRecordingGlobalHotkey = false
            return
        }
        isRecordingGlobalHotkey = true
        _ = TriggerRecorder.shared.start { trigger in
            isRecordingGlobalHotkey = false
            guard case let .keyboard(keyCode, modifiers) = trigger else {
                ToastCenter.shared.failure("全局开关不支持鼠标按键，请改按键盘组合")
                return
            }
            applyHotkeyConfig(HotkeyConfig(keyCode: keyCode, modifiers: modifiers))
        }
    }

    private func applyHotkeyConfig(_ cfg: HotkeyConfig?) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.updateGlobalHotkey(cfg)
        } else {
            preferences.update { $0.globalToggleHotkey = cfg }
        }
    }

    // MARK: - 导入 / 导出

    private func exportProfile(_ profile: AppProfile) {
        let safeName = profile.appName.replacingOccurrences(of: "/", with: "-")
        showSavePanel(suggestedName: "KeysMirror-\(safeName).json", profiles: [profile])
    }

    private func exportAll() {
        showSavePanel(suggestedName: "KeysMirror-AllProfiles.json", profiles: store.profiles)
    }

    private func showSavePanel(suggestedName: String, profiles: [AppProfile]) {
        let panel = NSSavePanel()
        panel.title = "导出 KeysMirror 配置"
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData(for: profiles).write(to: url, options: .atomic)
            ToastCenter.shared.success("已导出 \(profiles.count) 个配置到 \(url.lastPathComponent)")
        } catch {
            alert = ImportAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private func triggerImport(_ mode: ImportMode) {
        let panel = NSOpenPanel()
        panel.title = mode == .merge ? "选择要合并的 KeysMirror 配置" : "选择要导入为新配置的 KeysMirror 文件"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importProfiles(from: Data(contentsOf: url), mode: mode)
            ToastCenter.shared.success("已导入 \(count) 个配置（\(mode == .merge ? "合并" : "新建")模式）")
            if model.selectedProfileID == nil {
                model.selectedProfileID = store.profiles.first?.id
            }
        } catch {
            alert = ImportAlert(title: "导入失败", message: error.localizedDescription)
        }
    }
}

struct ImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
