import AppKit
import XCTest
@testable import KeysMirror

@MainActor
final class UndoCoordinatorTests: XCTestCase {
    private var coordinator: UndoCoordinator { UndoCoordinator.shared }

    override func setUp() {
        super.setUp()
        coordinator.reset()
    }

    override func tearDown() {
        coordinator.reset()
        super.tearDown()
    }

    // MARK: - 撤销 / 重做栈

    func testPerformRunsActionAndEnablesUndo() {
        var value = 0
        coordinator.perform(name: "加一", do: { value += 1 }, undo: { value -= 1 })
        XCTAssertEqual(value, 1)
        XCTAssertTrue(coordinator.canUndo)
        XCTAssertFalse(coordinator.canRedo)
    }

    func testUndoRestoresPreviousState() {
        var value = 0
        coordinator.perform(name: "加一", do: { value += 1 }, undo: { value -= 1 })
        coordinator.undo()
        XCTAssertEqual(value, 0)
        XCTAssertTrue(coordinator.canRedo)
    }

    func testRedoReappliesAction() {
        var value = 0
        coordinator.perform(name: "加一", do: { value += 1 }, undo: { value -= 1 })
        coordinator.undo()
        coordinator.redo()
        XCTAssertEqual(value, 1)
        XCTAssertTrue(coordinator.canUndo)
    }

    func testUndoRedoCyclesRepeatedly() {
        var value = 0
        coordinator.perform(name: "加一", do: { value += 1 }, undo: { value -= 1 })
        for _ in 0..<3 {
            coordinator.undo()
            XCTAssertEqual(value, 0)
            coordinator.redo()
            XCTAssertEqual(value, 1)
        }
    }

    func testMultipleActionsUndoInReverseOrder() {
        var log: [String] = []
        coordinator.perform(name: "A", do: { log.append("A") }, undo: { log.removeLast() })
        coordinator.perform(name: "B", do: { log.append("B") }, undo: { log.removeLast() })
        XCTAssertEqual(log, ["A", "B"])

        coordinator.undo()
        XCTAssertEqual(log, ["A"])
        coordinator.undo()
        XCTAssertTrue(log.isEmpty)
        XCTAssertFalse(coordinator.canUndo)
    }

    func testUndoOnEmptyStackIsNoop() {
        XCTAssertFalse(coordinator.canUndo)
        coordinator.undo()   // 不应崩溃
        XCTAssertFalse(coordinator.canRedo)
    }

    func testActionNameSurfacedForUI() {
        coordinator.perform(name: "删除映射", do: {}, undo: {})
        XCTAssertEqual(coordinator.undoActionName, "删除映射")
        coordinator.undo()
        XCTAssertEqual(coordinator.redoActionName, "删除映射")
    }

    // MARK: - ⌘Z 判定

    func testRecognizesCommandZ() {
        XCTAssertTrue(UndoCoordinator.isUndoShortcut(modifiers: [.command], characters: "z"))
        XCTAssertTrue(UndoCoordinator.isUndoShortcut(modifiers: [.command, .shift], characters: "Z"))
    }

    func testIgnoresOtherCombinations() {
        XCTAssertFalse(UndoCoordinator.isUndoShortcut(modifiers: [.command], characters: "y"))
        XCTAssertFalse(UndoCoordinator.isUndoShortcut(modifiers: [], characters: "z"))
        XCTAssertFalse(UndoCoordinator.isUndoShortcut(modifiers: [.command, .option], characters: "z"),
                       "⌥⌘Z 不属于撤销，不能吞掉")
        XCTAssertFalse(UndoCoordinator.isUndoShortcut(modifiers: [.command, .control], characters: "z"))
        XCTAssertFalse(UndoCoordinator.isUndoShortcut(modifiers: [.command], characters: nil))
    }

    // MARK: - store 侧的按位恢复

    func testDeletedMappingIsRestoredToItsOriginalIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let profile = try XCTUnwrap(store.profiles.first)

        let a = KeyMapping(keyCode: 0x00, relativeX: 0, relativeY: 0, label: "A")
        let b = KeyMapping(keyCode: 0x01, relativeX: 0, relativeY: 0, label: "B")
        let c = KeyMapping(keyCode: 0x02, relativeX: 0, relativeY: 0, label: "C")
        [a, b, c].forEach { store.addMapping($0, to: profile) }

        let index = try XCTUnwrap(store.indexOfMapping(b, in: profile))
        XCTAssertEqual(index, 1)

        store.deleteMapping(b, from: profile)
        XCTAssertEqual(store.profiles[0].mappings.map(\.label), ["A", "C"])

        store.insertMapping(b, at: index, in: profile)
        XCTAssertEqual(store.profiles[0].mappings.map(\.label), ["A", "B", "C"], "撤销删除要放回原位置，而不是追加到末尾")
    }

    func testInsertingAnExistingMappingIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let profile = try XCTUnwrap(store.profiles.first)
        let a = KeyMapping(keyCode: 0x00, relativeX: 0, relativeY: 0, label: "A")
        store.addMapping(a, to: profile)

        store.insertMapping(a, at: 0, in: profile)
        XCTAssertEqual(store.profiles[0].mappings.count, 1, "重复撤销不应产生副本")
    }

    func testDeletedMacroIsRestoredToItsOriginalIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let profile = try XCTUnwrap(store.profiles.first)

        let step = MacroStep(position: .inline(relativeX: 1, relativeY: 1, referenceWidth: nil, referenceHeight: nil))
        let m1 = MacroAction(label: "M1", keyCode: 0x7A, steps: [step])
        let m2 = MacroAction(label: "M2", keyCode: 0x78, steps: [step])
        [m1, m2].forEach { store.addMacro($0, to: profile) }

        let index = try XCTUnwrap(store.indexOfMacro(m1, in: profile))
        store.deleteMacro(m1, from: profile)
        store.insertMacro(m1, at: index, in: profile)
        XCTAssertEqual(store.profiles[0].macros.map(\.label), ["M1", "M2"])
    }

    func testDeletedProfileIsRestoredToItsOriginalIndex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.a", appName: "A")
        store.addProfile(bundleIdentifier: "com.b", appName: "B")
        store.addProfile(bundleIdentifier: "com.c", appName: "C")

        let b = store.profiles[1]
        let index = try XCTUnwrap(store.indexOfProfile(b))
        store.deleteProfile(b)
        store.restoreProfile(b, at: index)
        XCTAssertEqual(store.profiles.map(\.appName), ["A", "B", "C"])
    }

    /// 撤销一次删除后再撤销（Toast 与 ⌘Z 走同一条路径）不应把条目加两遍
    func testUndoIsIdempotentAcrossToastAndKeyboard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let profile = try XCTUnwrap(store.profiles.first)
        let a = KeyMapping(keyCode: 0x00, relativeX: 0, relativeY: 0, label: "A")
        store.addMapping(a, to: profile)

        coordinator.perform(
            name: "删除映射",
            do: { store.deleteMapping(a, from: profile) },
            undo: { store.insertMapping(a, at: 0, in: profile) }
        )
        XCTAssertTrue(store.profiles[0].mappings.isEmpty)

        coordinator.undo()               // Toast 上的「撤销」
        XCTAssertEqual(store.profiles[0].mappings.count, 1)

        coordinator.undo()               // 紧接着再按 ⌘Z：栈已空，什么都不该发生
        XCTAssertEqual(store.profiles[0].mappings.count, 1)
    }
}

// MARK: - 宏步骤级撤销

@MainActor
final class MacroStepUndoTests: XCTestCase {
    private var coordinator: UndoCoordinator { UndoCoordinator.shared }

    private func makeViewModel() -> MacroEditorViewModel {
        let profile = AppProfile(bundleIdentifier: "com.acme.app", appName: "App")
        // autosave: true 才会启用步骤撤销跟踪（Inspector 的用法）
        return MacroEditorViewModel(profile: profile, existingMacro: nil, autosave: true)
    }

    override func setUp() {
        super.setUp()
        coordinator.reset()
    }

    override func tearDown() {
        coordinator.reset()
        super.tearDown()
    }

    func testAddStepIsUndoable() {
        let vm = makeViewModel()
        vm.addStep()
        XCTAssertEqual(vm.steps.count, 1)

        coordinator.undo()
        XCTAssertTrue(vm.steps.isEmpty)

        coordinator.redo()
        XCTAssertEqual(vm.steps.count, 1)
    }

    func testRemoveStepIsUndoableAndKeepsOrder() {
        let vm = makeViewModel()
        vm.addStep()
        vm.addStep()
        vm.addStep()
        let ids = vm.steps.map(\.id)

        vm.removeStep(at: 1)
        XCTAssertEqual(vm.steps.map(\.id), [ids[0], ids[2]])

        coordinator.undo()
        XCTAssertEqual(vm.steps.map(\.id), ids, "撤销删除要放回原位置")
    }

    func testReorderIsUndoable() {
        let vm = makeViewModel()
        vm.addStep()
        vm.addStep()
        let ids = vm.steps.map(\.id)

        vm.moveSteps(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(vm.steps.map(\.id), [ids[1], ids[0]])

        coordinator.undo()
        XCTAssertEqual(vm.steps.map(\.id), ids)
    }

    func testDuplicateStepIsUndoable() {
        let vm = makeViewModel()
        vm.addStep()
        vm.steps[0].inlinePoint = CGPoint(x: 10, y: 20)
        vm.steps[0].inlineReferenceSize = CGSize(width: 800, height: 600)

        vm.duplicateStep(at: 0)
        XCTAssertEqual(vm.steps.count, 2)
        XCTAssertNotEqual(vm.steps[0].id, vm.steps[1].id, "副本要有自己的 id")

        coordinator.undo()
        XCTAssertEqual(vm.steps.count, 1)
    }

    func testNoOpMutationRegistersNothing() {
        let vm = makeViewModel()
        coordinator.reset()
        vm.removeStep(at: 99)          // 越界，什么都不该发生
        XCTAssertFalse(coordinator.canUndo)
    }

    func testDiscardingHistoryDropsThisEditorsEntries() {
        let vm = makeViewModel()
        vm.addStep()
        XCTAssertTrue(coordinator.canUndo)

        vm.discardStepUndoHistory()
        XCTAssertFalse(coordinator.canUndo, "编辑器关闭后不该还能撤销到它内部的状态")
    }

    func testDiscardingOneEditorKeepsOtherActions() {
        let vm = makeViewModel()
        var value = 0
        coordinator.perform(name: "无关操作", do: { value += 1 }, undo: { value -= 1 })
        vm.addStep()

        vm.discardStepUndoHistory()
        XCTAssertTrue(coordinator.canUndo, "别的操作不该被一并清掉")
        coordinator.undo()
        XCTAssertEqual(value, 0)
    }
}

// MARK: - 映射字段级撤销

@MainActor
final class MappingFieldUndoTests: XCTestCase {
    private var coordinator: UndoCoordinator { UndoCoordinator.shared }

    private func makeViewModel(existing: KeyMapping? = nil) -> MappingEditorViewModel {
        let profile = AppProfile(bundleIdentifier: "com.acme.app", appName: "App")
        return MappingEditorViewModel(profile: profile, existingMapping: existing, autosave: true)
    }

    override func setUp() {
        super.setUp()
        coordinator.reset()
    }

    override func tearDown() {
        coordinator.reset()
        super.tearDown()
    }

    /// 快照相等性是「输入合并」的基础：内容没变就不该产生撤销记录
    func testNoOpEditRegistersNothing() {
        let mapping = KeyMapping(keyCode: 0x0C, relativeX: 10, relativeY: 20, label: "攻击")
        let vm = makeViewModel(existing: mapping)
        coordinator.reset()

        vm.label = "攻击"          // 写回同样的值
        XCTAssertFalse(coordinator.canUndo, "内容没变不该压栈")
    }

    func testDraggingPointKeepsReferenceSize() {
        let mapping = KeyMapping(
            keyCode: 0x0C, relativeX: 10, relativeY: 20, label: "攻击",
            referenceWidth: 800, referenceHeight: 600
        )
        let vm = makeViewModel(existing: mapping)

        vm.updatePoint(CGPoint(x: 100, y: 200))
        XCTAssertEqual(vm.recordedPoint, CGPoint(x: 100, y: 200))
        XCTAssertEqual(vm.recordedReferenceSize, CGSize(width: 800, height: 600), "拖动只改坐标，不该丢缩放参考")
    }

    func testDiscardingHistoryKeepsOtherActions() {
        let vm = makeViewModel()
        var value = 0
        coordinator.perform(name: "无关操作", do: { value += 1 }, undo: { value -= 1 })

        vm.discardUndoHistory()
        XCTAssertTrue(coordinator.canUndo, "别的操作不该被一并清掉")
        coordinator.undo()
        XCTAssertEqual(value, 0)
    }
}
