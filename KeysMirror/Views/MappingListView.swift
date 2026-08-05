import SwiftUI

/// 映射列表。与宏列表**并列但独立**（评审决议：不合并成一个动作列表）。
struct MappingListView: View {
    let profile: AppProfile
    var searchText: String = ""
    let onEdit: (KeyMapping) -> Void
    let onDelete: (KeyMapping) -> Void
    let onToggleEnabled: (KeyMapping) -> Void
    var onDuplicate: ((KeyMapping) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if profile.mappings.isEmpty {
            EmptyStateView(
                title: "还没有映射",
                systemImage: "keyboard",
                description: "创建一条映射后，录制目标应用窗口中的点击位置。"
            )
        } else if filtered.isEmpty {
            EmptyStateView(
                title: "没有匹配的映射",
                systemImage: "magnifyingglass",
                description: "换个关键词试试，可以按名称或键位搜索。"
            )
        } else {
            List(filtered) { mapping in
                ActionRow(
                    title: mapping.label,
                    trigger: .init(mapping: mapping),
                    summary: "(\(Int(mapping.relativeX)), \(Int(mapping.relativeY)))",
                    state: mapping.isEnabled ? .enabled : .disabled,
                    badges: { scaleBadge(for: mapping) },
                    onToggleEnabled: { onToggleEnabled(mapping) },
                    onEdit: { onEdit(mapping) },
                    onDuplicate: onDuplicate.map { dup in { dup(mapping) } },
                    onDelete: { onDelete(mapping) }
                )
                .contextMenu {
                    Button("编辑") { onEdit(mapping) }
                    Button(mapping.isEnabled ? "禁用" : "启用") { onToggleEnabled(mapping) }
                    if let onDuplicate {
                        Button("复制") { onDuplicate(mapping) }
                    }
                    Divider()
                    Button("删除", role: .destructive) { onDelete(mapping) }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(Theme.Motion.standard(reduceMotion), value: profile.mappings)
        }
    }

    private var filtered: [KeyMapping] {
        Self.filter(profile.mappings, searchText: searchText)
    }

    /// 纯函数，便于单测：按名称或键位标签匹配（大小写不敏感）。
    static func filter(_ mappings: [KeyMapping], searchText: String) -> [KeyMapping] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return mappings }
        return mappings.filter {
            $0.label.localizedCaseInsensitiveContains(query) ||
            $0.displayShortcut.localizedCaseInsensitiveContains(query)
        }
    }

    /// 徽标只标**例外**：缩放跟随是正常状态，全部行都挂一个绿标只是噪音；
    /// 缺参考才是需要用户处理的情况，用 warning 色标出来。
    @ViewBuilder
    private func scaleBadge(for mapping: KeyMapping) -> some View {
        if !mapping.hasScaleReference {
            Badge(text: "无缩放参考", color: Theme.Palette.warning, systemImage: "exclamationmark.triangle.fill")
                .help("没有窗口尺寸快照，窗口缩放后点击会偏；编辑并重新录制位置即可启用缩放跟随")
        }
    }
}

/// 宏列表：与 MappingListView 并列在 profile 详情页里。
/// 运行中的宏行状态点变红并呼吸；提供启停 / 编辑 / 删除入口。
struct MacroListView: View {
    let profile: AppProfile
    /// 运行中的宏 id 集合（支持多条宏并行）
    let runningMacroIds: Set<UUID>
    var searchText: String = ""
    let onEdit: (MacroAction) -> Void
    let onDelete: (MacroAction) -> Void
    let onToggleEnabled: (MacroAction) -> Void
    var onDuplicate: ((MacroAction) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if profile.macros.isEmpty {
            EmptyStateView(
                title: "还没有宏",
                systemImage: "list.bullet.rectangle",
                description: "宏可以用一个触发键执行多步点击，并按秒/分延迟、循环 N 次或无限。"
            )
        } else if filtered.isEmpty {
            EmptyStateView(
                title: "没有匹配的宏",
                systemImage: "magnifyingglass",
                description: "换个关键词试试，可以按名称或键位搜索。"
            )
        } else {
            List(filtered) { macro in
                ActionRow(
                    title: macro.label,
                    trigger: .init(macro: macro),
                    summary: macro.stepSummary,
                    state: runningMacroIds.contains(macro.id) ? .running : (macro.isEnabled ? .enabled : .disabled),
                    badges: { multiClickBadge(for: macro) },
                    onToggleEnabled: { onToggleEnabled(macro) },
                    onEdit: { onEdit(macro) },
                    onDuplicate: onDuplicate.map { dup in { dup(macro) } },
                    onDelete: { onDelete(macro) }
                )
                .contextMenu {
                    Button("编辑") { onEdit(macro) }
                    Button(macro.isEnabled ? "禁用" : "启用") { onToggleEnabled(macro) }
                    if let onDuplicate {
                        Button("复制") { onDuplicate(macro) }
                    }
                    Divider()
                    Button("删除", role: .destructive) { onDelete(macro) }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .animation(Theme.Motion.standard(reduceMotion), value: profile.macros)
        }
    }

    private var filtered: [MacroAction] {
        Self.filter(profile.macros, searchText: searchText)
    }

    static func filter(_ macros: [MacroAction], searchText: String) -> [MacroAction] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return macros }
        return macros.filter {
            $0.label.localizedCaseInsensitiveContains(query) ||
            $0.displayShortcut.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private func multiClickBadge(for macro: MacroAction) -> some View {
        let maxClicks = macro.steps.map(\.clickCount).max() ?? 1
        if maxClicks > 1 {
            Badge(text: "连击 ×\(maxClicks)", color: Theme.Palette.accent)
                .help("存在同一位置连点多次的步骤")
        }
    }
}

// MARK: - KeyCapView.Trigger 便捷构造

extension KeyCapView.Trigger {
    init(mapping: KeyMapping) {
        switch mapping.triggerType {
        case .keyboard: self = .keyboard(keyCode: mapping.keyCode, modifiers: mapping.modifiers)
        case .mouseRight: self = .mouseRight
        case .mouseOther: self = .mouseOther(buttonNumber: mapping.mouseButtonNumber)
        }
    }

    init(macro: MacroAction) {
        switch macro.triggerType {
        case .keyboard: self = .keyboard(keyCode: macro.keyCode, modifiers: macro.modifiers)
        case .mouseRight: self = .mouseRight
        case .mouseOther: self = .mouseOther(buttonNumber: macro.mouseButtonNumber)
        }
    }
}
