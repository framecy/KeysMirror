import SwiftUI

@MainActor
final class ConfigurationWindowController {
    static let shared = ConfigurationWindowController()

    private var window: NSWindow?
    private var willCloseObserver: NSObjectProtocol?

    /// 测试钩子：close 后 willClose 通知必须把强引用清干净。
    var hasWindowReference: Bool { window != nil }

    func show() {
        // 主防线：isReleasedWhenClosed = false 让 close 不释放底层对象。
        // 副防线：监听 willClose，发生时主动 nil 强引用——即使主防线被未来重构误删，
        // 下次 show() 看到 nil 直接重建，杜绝野指针 objc_msgSend 闪退。
        if window == nil {
            let rootView = ConfigurationWindow()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "KeysMirror 配置"
            window.center()
            window.contentView = NSHostingView(rootView: rootView)

            // 副防线只在「窗口即将真的被释放」时触发：
            // 正常情况下 isReleasedWhenClosed=false，close 只是隐藏，引用保留以复用 SwiftUI 状态；
            // 若未来重构误把 isReleasedWhenClosed 改回 true（默认值），close 后底层会释放，
            // 这里在 dealloc 之前主动 nil 强引用，下次 show() 看到 nil 直接重建，不会野指针闪退。
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // observer 已绑定到特定 window（object: window），每次回调一定是这个窗口，
                // 不必从 note 解包——note: Notification 不 Sendable，跨 actor 传会被 strict
                // concurrency 拦下。直接通过 self.window 检查 isReleasedWhenClosed。
                MainActor.assumeIsolated {
                    guard self?.window?.isReleasedWhenClosed == true else { return }
                    self?.releaseWindow()
                }
            }

            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func releaseWindow() {
        if let obs = willCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            willCloseObserver = nil
        }
        window = nil
    }
}

struct ConfigurationWindow: View {
    @StateObject private var store = MappingStore.shared
    @StateObject private var permissionChecker = PermissionChecker.shared
    @StateObject private var logger = AppLogger.shared
    @StateObject private var preferences = PreferencesStore.shared
    @StateObject private var macroRunner = MacroRunner.shared
    @State private var selectedProfileID: UUID?
    @State private var showingAppPicker = false
    @State private var editingMapping: EditingMapping?
    @State private var editingMacro: EditingMacro?
    @State private var showLogs = false
    @State private var importAlert: ImportAlert?
    @State private var isRecordingGlobalHotkey = false

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("应用配置")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Menu {
                        Button("导出全部配置...") { exportAll() }
                            .disabled(store.profiles.isEmpty)
                        Divider()
                        Button("导入并合并...") { triggerImport(.merge) }
                        Button("导入为新配置...") { triggerImport(.addAsNew) }
                    } label: {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 28)
                    .help("导入 / 导出配置（合并 = 同 bundleId 覆盖；新建 = 全部追加）")

                    Button("添加应用") {
                        showingAppPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                globalHotkeyRow
                    .padding(10)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                if store.profiles.isEmpty {
                    EmptyStateView(
                        title: "还没有应用配置",
                        systemImage: "keyboard.badge.eye",
                        description: "先添加一个正在运行的应用，再为它录制按键和点击位置。"
                    )
                } else {
                    List(selection: $selectedProfileID) {
                        ForEach(store.profiles) { profile in
                            Label(profile.appName, systemImage: profile.isEnabled ? "app.fill" : "app")
                                .tag(profile.id)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        store.deleteProfile(profile)
                                        if selectedProfileID == profile.id {
                                            selectedProfileID = store.profiles.first?.id
                                        }
                                    } label: {
                                        Label("删除配置", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete(perform: deleteProfiles)
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                if !permissionChecker.isAccessibilityGranted {
                    permissionBanner
                }

                if let profile = selectedProfile {
                    profileDetail(profile)
                } else {
                    EmptyStateView(
                        title: "请选择一个应用",
                        systemImage: "cursorarrow.click",
                        description: "在左侧选择应用后，才能管理它的按键映射。"
                    )
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingAppPicker) {
            AppPickerView { application in
                store.addProfile(bundleIdentifier: application.bundleIdentifier, appName: application.displayName)
                if let addedProfile = store.profiles.first(where: { $0.bundleIdentifier == application.bundleIdentifier }) {
                    selectedProfileID = addedProfile.id
                }
            }
        }
        .sheet(item: $editingMapping) { editing in
            MappingEditorView(profile: editing.profile, existingMapping: editing.mapping)
        }
        .sheet(item: $editingMacro) { editing in
            MacroEditorView(profile: editing.profile, existingMacro: editing.macro)
        }
        .onAppear {
            permissionChecker.refreshStatus()
            if selectedProfileID == nil {
                selectedProfileID = store.profiles.first?.id
            }
        }
        .alert(item: $importAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("好")))
        }
    }

    private var selectedProfile: AppProfile? {
        store.profiles.first(where: { $0.id == selectedProfileID })
    }

    private var globalHotkeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("全局开关快捷键")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                Text(globalHotkeyLabel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isRecordingGlobalHotkey ? .secondary : .primary)
                Spacer()
                Button(isRecordingGlobalHotkey ? "等待按键..." : "修改") {
                    startRecordingGlobalHotkey()
                }
                .controlSize(.small)
                if preferences.preferences.globalToggleHotkey != nil && !isRecordingGlobalHotkey {
                    Button("清除") {
                        clearGlobalHotkey()
                    }
                    .controlSize(.small)
                }
            }
            Text("在任意应用按下此快捷键即可启用 / 禁用映射。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var globalHotkeyLabel: String {
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
                importAlert = ImportAlert(title: "仅支持键盘组合", message: "全局开关 hotkey 不支持鼠标按键，请改按键盘组合。")
                return
            }
            let cfg = HotkeyConfig(keyCode: keyCode, modifiers: modifiers)
            applyHotkeyConfig(cfg)
        }
    }

    private func clearGlobalHotkey() {
        applyHotkeyConfig(nil)
    }

    private func applyHotkeyConfig(_ cfg: HotkeyConfig?) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.updateGlobalHotkey(cfg)
        } else {
            preferences.update { $0.globalToggleHotkey = cfg }
        }
    }

    private var permissionBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("需要先授予“辅助功能”权限，才能拦截按键和模拟鼠标点击。")
            Spacer()
            Button("去授权") {
                PermissionChecker.shared.requestAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func profileDetail(_ profile: AppProfile) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.appName)
                    .font(.title.weight(.semibold))
                Text(profile.bundleIdentifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("启用此配置", isOn: Binding(
                    get: { profile.isEnabled },
                    set: { newValue in
                        var updated = profile
                        updated.isEnabled = newValue
                        store.updateProfile(updated)
                    }
                ))
                .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button {
                        exportProfile(profile)
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        store.deleteProfile(profile)
                        selectedProfileID = store.profiles.first?.id
                    } label: {
                        Label("删除此配置", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Toggle("显示快捷键指示器", isOn: Binding(
                get: { profile.showOverlay },
                set: { newValue in
                    var updated = profile
                    updated.showOverlay = newValue
                    store.updateProfile(updated)
                }
            ))
            .toggleStyle(.switch)

            Text("指示器透明度: \(Int(profile.overlayOpacity * 100))%")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { profile.overlayOpacity },
                set: { newValue in
                    var updated = profile
                    updated.overlayOpacity = newValue
                    store.updateProfile(updated)
                }
            ), in: 0...1)
            .tint(.accentColor)
        }
        .padding(.vertical, 8)

        HStack {
            Text("映射列表")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("新建映射") {
                editingMapping = EditingMapping(profile: profile, mapping: nil)
            }
            .buttonStyle(.borderedProminent)
        }

        MappingListView(
            profile: profile,
            onEdit: { mapping in
                editingMapping = EditingMapping(profile: profile, mapping: mapping)
            },
            onDelete: { mapping in
                store.deleteMapping(mapping, from: profile)
            },
            onToggleEnabled: { mapping in
                var updated = mapping
                updated.isEnabled.toggle()
                store.updateMapping(updated, in: profile)
            }
        )

        Divider()
            .padding(.vertical, 8)

        HStack {
            Text("宏 (Macros)")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("新建宏") {
                editingMacro = EditingMacro(profile: profile, macro: nil)
            }
            .buttonStyle(.borderedProminent)
        }

        MacroListView(
            profile: profile,
            runningMacroId: macroRunner.runningMacroId,
            onEdit: { macro in
                editingMacro = EditingMacro(profile: profile, macro: macro)
            },
            onDelete: { macro in
                if macroRunner.runningMacroId == macro.id {
                    macroRunner.stop(reason: "用户删除宏")
                }
                store.deleteMacro(macro, from: profile)
            },
            onToggleEnabled: { macro in
                if macroRunner.runningMacroId == macro.id && macro.isEnabled {
                    macroRunner.stop(reason: "用户禁用宏")
                }
                var updated = macro
                updated.isEnabled.toggle()
                store.updateMacro(updated, in: profile)
            }
        )

        Divider()
            .padding(.vertical, 8)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showLogs.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showLogs ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                        Text("运行日志")
                            .font(.headline)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if showLogs {
                    Button("导出") {
                        exportLogs()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([logger.currentLogFileURL])
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)

                    Button("清空") {
                        logger.clear()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                }
            }

            if showLogs {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(logger.logs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(
                                        log.contains("[ERROR]") ? .red :
                                        log.contains("[WARN]")  ? .orange : .secondary
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 150)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(8)
                    .onChange(of: logger.logs.count) { _ in
                        proxy.scrollTo(0)
                    }
                }
            }
        }
    }

    private func deleteProfiles(at offsets: IndexSet) {
        let profiles = offsets.compactMap { index in
            store.profiles.indices.contains(index) ? store.profiles[index] : nil
        }

        for profile in profiles {
            store.deleteProfile(profile)
        }

        if !store.profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = store.profiles.first?.id
        }
    }

    // MARK: - 日志导出

    private func exportLogs() {
        let panel = NSSavePanel()
        panel.title = "导出 KeysMirror 日志"
        let stamp = Self.logFilenameFormatter.string(from: Date())
        panel.nameFieldStringValue = "KeysMirror-log-\(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logger.exportSnapshot().write(to: url, options: .atomic)
            importAlert = ImportAlert(title: "日志已导出", message: "已写入 \(url.lastPathComponent)")
        } catch {
            importAlert = ImportAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    private static let logFilenameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: - 导入 / 导出

    private func exportProfile(_ profile: AppProfile) {
        let safeName = profile.appName.replacingOccurrences(of: "/", with: "-")
        let suggested = "KeysMirror-\(safeName).json"
        showSavePanel(suggestedName: suggested, profiles: [profile])
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
            let data = try store.exportData(for: profiles)
            try data.write(to: url, options: .atomic)
            importAlert = ImportAlert(title: "导出成功", message: "已写入 \(url.lastPathComponent)（\(profiles.count) 个配置）")
        } catch {
            importAlert = ImportAlert(title: "导出失败", message: error.localizedDescription)
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
            let data = try Data(contentsOf: url)
            let count = try store.importProfiles(from: data, mode: mode)
            importAlert = ImportAlert(title: "导入成功", message: "已导入 \(count) 个配置（\(mode == .merge ? "合并" : "新建")模式）")
            if selectedProfileID == nil {
                selectedProfileID = store.profiles.first?.id
            }
        } catch {
            importAlert = ImportAlert(title: "导入失败", message: error.localizedDescription)
        }
    }
}

struct ImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct EditingMapping: Identifiable {
    let id = UUID()
    let profile: AppProfile
    let mapping: KeyMapping?
}

struct EditingMacro: Identifiable {
    let id = UUID()
    let profile: AppProfile
    let macro: MacroAction?
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
