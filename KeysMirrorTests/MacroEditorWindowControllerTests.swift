import AppKit
import XCTest
@testable import KeysMirror

/// 回归覆盖 A1（草稿保存后窗口未重绑，导致同一条宏被两扇窗口同时编辑）
/// 与 A2（录制结束把所有宏窗口一起拽到最前）。
///
/// `MacroEditorWindowController` 管理的是真实 `NSWindow`；`MacroInspector` 内部创建的
/// `MacroEditorViewModel` 是私有 `@StateObject`，没有反射意义上的稳定方式够到它。
/// 所以这里把「A1 这条因果链」拆成两段各自验证，合起来就是端到端正确：
/// 1) `MacroEditorViewModel.onFirstCommit` 在草稿第一次保存时且仅那一次触发（本文件）；
/// 2) 控制器收到回调后确实把窗口从旧 key 重绑到新 key，而不是新开一扇（本文件 + 内部可见的
///    `rebind` / `key(for:)` / `windowExists(forKey:)` 测试用入口）。
@MainActor
final class MacroEditorWindowControllerTests: XCTestCase {
    private let controller = MacroEditorWindowController.shared

    private func makeProfile() -> AppProfile {
        AppProfile(bundleIdentifier: "com.acme.app", appName: "App")
    }

    private func makeMacro(label: String = "连点") -> MacroAction {
        MacroAction(
            label: label, triggerType: .keyboard, keyCode: 0x7A,
            steps: [MacroStep(position: .inline(relativeX: 1, relativeY: 2, referenceWidth: nil, referenceHeight: nil))]
        )
    }

    override func tearDown() {
        // 关掉本用例开的所有窗口，避免污染下一个用例
        for window in NSApp.windows where window.title.hasPrefix("宏") || window.title == "新建宏" {
            window.close()
        }
        super.tearDown()
    }

    // MARK: - A1：草稿保存后重绑，而不是新开一扇窗口

    func testKeyForSameMacroIsStable() {
        let macro = makeMacro()
        XCTAssertEqual(MacroEditorWindowController.key(for: macro), MacroEditorWindowController.key(for: macro))
    }

    func testKeyForDifferentMacrosDiffers() {
        XCTAssertNotEqual(
            MacroEditorWindowController.key(for: makeMacro(label: "A")),
            MacroEditorWindowController.key(for: makeMacro(label: "B"))
        )
    }

    /// 核心回归：打开草稿 → 模拟它第一次自动保存（真实 `MacroEditorViewModel.commit()`
    /// 触发 `onFirstCommit`，回调里做的事情与 `open()` 内部接线完全一致的 `rebind`）→
    /// 用真实 macro id 再 `open` 一次，必须命中同一扇窗口，而不是多开一扇。
    ///
    /// 注意：`commit()` 在 `existingMacro == nil` 时会自己生成一个新 `UUID` 当 id
    /// （`id: existingMacro?.id ?? UUID()`），不是外部随便指定的——所以断言必须用
    /// `onFirstCommit` 回调里拿到的那个 `saved` 的 id，不能假设它等于测试里另造的 macro。
    func testDraftRebindsToRealMacroIdOnFirstCommit() {
        let profile = makeProfile()
        let template = makeMacro()

        controller.open(profile: profile, macro: nil)
        guard let draftWindow = NSApp.windows.first(where: { $0.title == "新建宏" }) else {
            XCTFail("打开草稿后应该能找到「新建宏」窗口")
            return
        }
        guard let oldKey = controller.key(forWindow: draftWindow) else {
            XCTFail("应该能反查出草稿窗口当前的 key")
            return
        }
        let countAfterDraftOpen = controller.openWindowCount

        // 模拟 MacroEditorViewModel.commit() 里 wasDraft→false 时触发的回调路径：
        // 直接构造一个 view model，接上与 open() 里同样的 onFirstCommit 逻辑。
        let vm = MacroEditorViewModel(profile: profile, existingMacro: nil, autosave: false)
        vm.label = template.label
        vm.recordedTriggerType = .keyboard
        vm.recordedKeyCode = template.keyCode
        vm.steps = template.steps.map { EditableStep(step: $0) }

        var committed: MacroAction?
        vm.onFirstCommit = { [weak controller] saved in
            committed = saved
            controller?.rebind(
                from: oldKey,
                to: MacroEditorWindowController.key(for: saved),
                window: draftWindow,
                title: "宏 · \(saved.label)"
            )
        }
        XCTAssertTrue(vm.commit(), "构造的宏应该满足 canSave，commit 才会真的触发 onFirstCommit")
        guard let savedMacro = committed else {
            XCTFail("onFirstCommit 应该已经触发过一次")
            return
        }

        // 窗口数量不变（没有多开），且真实 id 对应的 key 现在指向同一扇窗口
        XCTAssertEqual(controller.openWindowCount, countAfterDraftOpen, "重绑不应该产生新窗口")
        let realKey = MacroEditorWindowController.key(for: savedMacro)
        XCTAssertTrue(controller.windowExists(forKey: realKey), "重绑后应该能用真实 macro id 的 key 找到窗口")
        XCTAssertFalse(controller.windowExists(forKey: oldKey), "旧的 draft key 不该再指向任何窗口")
        XCTAssertEqual(draftWindow.title, "宏 · \(savedMacro.label)", "窗口标题也要跟着更新")

        // 这才是 A1 真正要守住的行为：随后「从列表点编辑同一条宏」必须前置到刚才那扇窗口，
        // 而不是因为找不到旧 key 又新开一扇。
        controller.open(profile: profile, macro: savedMacro)
        XCTAssertEqual(controller.openWindowCount, countAfterDraftOpen, "编辑同一条宏不应该多开窗口")
    }

    func testOpeningSameMacroTwiceReusesWindow() {
        let profile = makeProfile()
        let macro = makeMacro()

        controller.open(profile: profile, macro: macro)
        let countAfterFirstOpen = controller.openWindowCount

        controller.open(profile: profile, macro: macro)
        XCTAssertEqual(controller.openWindowCount, countAfterFirstOpen, "同一条宏重复打开不应该多开窗口")
    }

    func testCloseRemovesWindowForMacroId() {
        let profile = makeProfile()
        let macro = makeMacro()

        controller.open(profile: profile, macro: macro)
        XCTAssertTrue(controller.windowExists(forKey: MacroEditorWindowController.key(for: macro)))

        controller.close(macroId: macro.id)
        XCTAssertFalse(controller.windowExists(forKey: MacroEditorWindowController.key(for: macro)))
    }

    // MARK: - A2：录制结束只恢复被录制打断的那一扇窗口

    func testHideForRecordingOnlyTouchesKeyWindow() {
        let profile = makeProfile()
        let macroA = makeMacro(label: "A")
        let macroB = makeMacro(label: "B")

        controller.open(profile: profile, macro: macroA)
        controller.open(profile: profile, macro: macroB)  // 后打开的是当前 key window

        guard let windowA = NSApp.windows.first(where: { $0.title == "宏 · A" }),
              let windowB = NSApp.windows.first(where: { $0.title == "宏 · B" }) else {
            XCTFail("两扇宏窗口都应该能找到")
            return
        }
        XCTAssertTrue(windowB.isKeyWindow, "后打开的窗口应该是当前 key window")

        controller.hideForRecording()

        XCTAssertFalse(windowB.isVisible, "正在操作的那扇窗口应该让位给目标 app")
        XCTAssertTrue(windowA.isVisible, "没有参与录制的窗口不该被一起隐藏")

        controller.restoreFromRecording()
        XCTAssertTrue(windowB.isVisible, "录制结束应该恢复原来那扇窗口")
    }

    func testHideForRecordingIsNoopWhenNoMacroWindowIsFocused() {
        // 没有任何宏窗口时调用不应该崩溃，也不该留下悬空的 hiddenForRecording 状态
        controller.hideForRecording()
        controller.restoreFromRecording()
        XCTAssertEqual(controller.openWindowCount, 0)
    }
}
