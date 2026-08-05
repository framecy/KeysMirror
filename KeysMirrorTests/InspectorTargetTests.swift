import XCTest
@testable import KeysMirror

/// 回归测试（承接旧的 MacroEditorIdentityTests）：
/// sheet 时代「点编辑打开的还是上一次新建的表单」源于视图身份复用。
/// 换成 Inspector 后同样的风险仍在——Inspector 用 `target.id` 驱动 `.id()`，
/// 所以这里守住：新建 / 编辑 / 不同条目的 id 必须互不相同。
///
/// 注：宏已改为独立窗口（MacroEditorWindowController 按 macro id 去重），
/// 不再走 Inspector，因此这里只覆盖映射。
@MainActor
final class InspectorTargetTests: XCTestCase {
    private typealias Target = MainWindowModel.InspectorTarget

    func testDraftAndEditIdsDiffer() {
        XCTAssertNotEqual(Target.draftMapping(UUID()).id, Target.mapping(UUID()).id)
    }

    func testSameEntityKeepsStableId() {
        let id = UUID()
        XCTAssertEqual(Target.mapping(id).id, Target.mapping(id).id)
    }

    func testDifferentEntitiesProduceDifferentIds() {
        XCTAssertNotEqual(Target.mapping(UUID()).id, Target.mapping(UUID()).id)
    }

    func testTwoDraftsAreDistinct() {
        XCTAssertNotEqual(Target.draftMapping(UUID()).id, Target.draftMapping(UUID()).id)
    }

    // MARK: - 选中项被删除后 Inspector 要清空

    func testClearInspectorWhenSelectedMappingDeleted() {
        let model = MainWindowModel()
        let id = UUID()
        model.inspectorTarget = .mapping(id)
        model.clearInspectorIfNeeded(deletedId: id)
        XCTAssertNil(model.inspectorTarget)
    }

    func testKeepInspectorWhenOtherEntityDeleted() {
        let model = MainWindowModel()
        let id = UUID()
        model.inspectorTarget = .mapping(id)
        model.clearInspectorIfNeeded(deletedId: UUID())
        XCTAssertEqual(model.inspectorTarget, .mapping(id))
    }
}
