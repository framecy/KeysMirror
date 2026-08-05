import AppKit
import SwiftUI

/// 主窗状态。原先散落在 ConfigurationWindow 的 8 个 @State 收敛到这里。
@MainActor
final class MainWindowModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case mappings, macros
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .mappings: return "keyboard"
            case .macros: return "play.rectangle"
            }
        }
    }

    /// Inspector 当前编辑的对象。切换时用 id 驱动 `.id()` 强制重建，
    /// 避免「打开的还是上一条的编辑器」（旧 sheet 时代的回归问题，见 InspectorTargetTests）。
    /// Inspector 只承载**映射**。宏走独立窗口（`MacroEditorWindowController`）：
    /// 一个宏动辄七八步、每步四组控件，侧栏宽度怎么排都是挤的。
    enum InspectorTarget: Identifiable, Hashable {
        case mapping(UUID)
        case draftMapping(UUID)

        var id: String {
            switch self {
            case .mapping(let id): return "mapping-\(id.uuidString)"
            case .draftMapping(let id): return "draft-mapping-\(id.uuidString)"
            }
        }
    }

    @Published var selectedProfileID: UUID?
    @Published var section: Section = .mappings
    @Published var searchText: String = ""
    /// Inspector 的显隐直接由 `inspectorTarget != nil` 驱动，不需要单独的开关状态。
    @Published var inspectorTarget: InspectorTarget?
    /// 侧栏显隐由我们自己控制（不再交给 NavigationSplitView，免得头栏按钮跟着移动）
    @Published var sidebarVisible: Bool = true
    @Published var showAppPicker = false
    @Published var pendingProfileDeletion: AppProfile?

    /// 新建时用一次性 id 生成草稿身份，保证与「编辑第 N 条」互不复用视图身份。
    func startNewMapping() {
        section = .mappings
        inspectorTarget = .draftMapping(UUID())
    }

    /// 宏：开独立窗口，不占 Inspector
    func startNewMacro(profile: AppProfile) {
        section = .macros
        MacroEditorWindowController.shared.open(profile: profile, macro: nil)
    }

    func edit(mapping: KeyMapping) {
        section = .mappings
        inspectorTarget = .mapping(mapping.id)
    }

    func edit(macro: MacroAction, in profile: AppProfile) {
        section = .macros
        MacroEditorWindowController.shared.open(profile: profile, macro: macro)
    }

    /// 选中项被删除后清理 Inspector；宏则关掉它的独立窗口
    func clearInspectorIfNeeded(deletedId: UUID) {
        if case .mapping(let id) = inspectorTarget, id == deletedId {
            inspectorTarget = nil
        }
        MacroEditorWindowController.shared.close(macroId: deletedId)
    }
}
