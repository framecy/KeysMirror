import SwiftUI

@MainActor
final class ConfigurationWindowController {
    static let shared = ConfigurationWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let rootView = ConfigurationWindow()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "KeysMirror 配置"
            window.center()
            window.contentView = NSHostingView(rootView: rootView)
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct ConfigurationWindow: View {
    @StateObject private var store = MappingStore.shared
    @StateObject private var permissionChecker = PermissionChecker.shared
    @State private var selectedProfileID: UUID?
    @State private var showingAppPicker = false
    @State private var editingMapping: EditingMapping?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("应用配置")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("添加应用") {
                        showingAppPicker = true
                    }
                    .buttonStyle(.borderedProminent)
                }

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
        .onAppear {
            permissionChecker.refreshStatus()
            if selectedProfileID == nil {
                selectedProfileID = store.profiles.first?.id
            }
        }
    }

    private var selectedProfile: AppProfile? {
        store.profiles.first(where: { $0.id == selectedProfileID })
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
            }
        )

        Divider()
            .padding(.vertical, 8)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("运行日志")
                    .font(.headline)
                Spacer()
                Button("清空日志") {
                    AppLogger.shared.clear()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(AppLogger.shared.logs.enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(log.contains("[ERROR]") ? .red : (log.contains("[WARN]") ? .yellow : .secondary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 120)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
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
}

struct EditingMapping: Identifiable {
    let id = UUID()
    let profile: AppProfile
    let mapping: KeyMapping?
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
