import XCTest
@testable import KeysMirror

/// 重构后新增纯逻辑的测试：列表过滤、键位占用、HUD 数据源、HUD 布局。
@MainActor
final class UIModelTests: XCTestCase {

    private func mapping(_ label: String, keyCode: UInt16 = 0x0C, modifiers: UInt64 = 0) -> KeyMapping {
        KeyMapping(keyCode: keyCode, modifiers: modifiers, relativeX: 10, relativeY: 20, label: label)
    }

    private func macro(_ label: String, keyCode: UInt16 = 0x7A) -> MacroAction {
        MacroAction(
            label: label,
            triggerType: .keyboard,
            keyCode: keyCode,
            steps: [MacroStep(position: .inline(relativeX: 1, relativeY: 2, referenceWidth: nil, referenceHeight: nil))]
        )
    }

    // MARK: - 列表过滤

    func testEmptyQueryReturnsEverything() {
        let items = [mapping("攻击"), mapping("技能")]
        XCTAssertEqual(MappingListView.filter(items, searchText: "   ").count, 2)
    }

    func testFilterMatchesLabelCaseInsensitively() {
        let items = [mapping("Attack"), mapping("技能")]
        XCTAssertEqual(MappingListView.filter(items, searchText: "att").map(\.label), ["Attack"])
    }

    func testFilterMatchesShortcutLabel() {
        // keyCode 0x0C = Q
        let items = [mapping("攻击", keyCode: 0x0C), mapping("技能", keyCode: 0x0E)]
        XCTAssertEqual(MappingListView.filter(items, searchText: "q").map(\.label), ["攻击"])
    }

    func testMacroFilterWorksOnItsOwnList() {
        let items = [macro("连点"), macro("挂机")]
        XCTAssertEqual(MacroListView.filter(items, searchText: "挂").map(\.label), ["挂机"])
    }

    // MARK: - 键位占用（映射与宏共享触发器空间）

    func testOccupanciesIncludeBothKinds() {
        let profile = AppProfile(
            bundleIdentifier: "com.acme.app",
            appName: "App",
            mappings: [mapping("攻击", keyCode: 0x0C)],
            macros: [macro("连点", keyCode: 0x7A)]
        )
        let all = profile.triggerOccupancies
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.kind, .mapping)
        XCTAssertEqual(all.last?.kind, .macro)
        XCTAssertEqual(all.last?.kindText, "宏")
    }

    func testOccupanciesForKeyCodeFindsOwner() throws {
        let profile = AppProfile(
            bundleIdentifier: "com.acme.app",
            appName: "App",
            mappings: [mapping("攻击", keyCode: 0x0C)],
            macros: [macro("连点", keyCode: 0x7A)]
        )
        let owner = try XCTUnwrap(profile.occupancies(forKeyCode: 0x7A).first)
        XCTAssertEqual(owner.label, "连点")
        XCTAssertEqual(owner.kind, .macro)
        XCTAssertTrue(profile.occupancies(forKeyCode: 0x0E).isEmpty)
    }

    func testTriggerOwnerNamesTheConflictingEntity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let profile = try XCTUnwrap(store.profiles.first)
        store.addMacro(macro("连点", keyCode: 0x7A), to: profile)

        let owner = try XCTUnwrap(store.triggerOwner(
            triggerType: .keyboard, keyCode: 0x7A, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))
        XCTAssertEqual(owner.label, "连点")
        XCTAssertEqual(owner.kind, .macro)

        XCTAssertNil(store.triggerOwner(
            triggerType: .keyboard, keyCode: 0x0C, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))
    }

    func testRestoreProfileUndoesDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.addProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let profile = try XCTUnwrap(store.profiles.first)

        store.deleteProfile(profile)
        XCTAssertTrue(store.profiles.isEmpty)

        store.restoreProfile(profile)
        XCTAssertEqual(store.profiles.count, 1)
        // 重复恢复不应产生副本
        store.restoreProfile(profile)
        XCTAssertEqual(store.profiles.count, 1)
    }

    // MARK: - 游戏内 HUD

    // MARK: - 菜单栏宏跑马灯
    //
    // v1.6.3：游戏内 HUD 已删除，运行中的宏改为在系统状态栏横向滚动展示。

    func testMarqueeComposesLabelAndCount() {
        let macros = [
            RunningMacro(id: UUID(), label: "钓鱼", bundleId: "a", iteration: 12, total: 50),
            RunningMacro(id: UUID(), label: "打怪", bundleId: "a", iteration: 7, total: nil),
        ]
        XCTAssertEqual(MacroMarqueeView.compose(macros), "钓鱼 12/50  ·  打怪 7/∞")
    }

    func testMarqueeComposeEmptyWhenNothingRunning() {
        XCTAssertEqual(MacroMarqueeView.compose([]), "")
    }

    func testProgressTextHandlesFiniteAndInfinite() {
        XCTAssertEqual(MacroMarqueeView.progressText(iteration: 12, total: 50), "12/50")
        XCTAssertEqual(MacroMarqueeView.progressText(iteration: 7, total: nil), "7/∞")
    }

    /// 位移越过一轮长度后必须回卷，否则文本会一直往左飘出视野再也不回来。
    func testMarqueeOffsetWrapsAroundExactlyOnce() {
        let loop: CGFloat = 100
        XCTAssertEqual(MacroMarqueeView.advance(offset: 0, by: 0.7, loopWidth: loop), 0.7, accuracy: 0.0001)
        XCTAssertEqual(MacroMarqueeView.advance(offset: 99.5, by: 0.7, loopWidth: loop), 0.2, accuracy: 0.0001)
        // 恰好等于一轮长度时也要归零，不能停在边界上
        XCTAssertEqual(MacroMarqueeView.advance(offset: 99.3, by: 0.7, loopWidth: loop), 0, accuracy: 0.0001)
    }

    func testMarqueeOffsetStaysZeroWithoutContent() {
        XCTAssertEqual(MacroMarqueeView.advance(offset: 5, by: 0.7, loopWidth: 0), 0)
    }

    /// 内容比可视区窄时不滚动——短名称固定显示更好读。
    func testMarqueeOnlyScrollsWhenContentOverflows() {
        XCTAssertFalse(MacroMarqueeView.shouldScroll(contentWidth: 80, visibleWidth: 132))
        XCTAssertFalse(MacroMarqueeView.shouldScroll(contentWidth: 132, visibleWidth: 132))
        XCTAssertTrue(MacroMarqueeView.shouldScroll(contentWidth: 133, visibleWidth: 132))
    }

    // MARK: - 数据兼容

    func testLegacyProfileWithoutHUDFieldsDecodesToDefaults() throws {
        let json = """
        {"bundleIdentifier":"com.acme.app","appName":"App","mappings":[],"isEnabled":true}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AppProfile.self, from: json)
        XCTAssertTrue(profile.showHUD)
        XCTAssertEqual(profile.hudMode, .full)
        XCTAssertEqual(profile.hudCorner, .topTrailing)
        XCTAssertEqual(profile.hudLogFilter, .actionsOnly)
    }

    /// v1.6 曾有 hudOpacity 字段；HUD 已改为固定不透明，字段已删。
    /// 旧数据里残留这个 key 应被安全忽略，不能导致解码失败。
    func testLegacyProfileWithStaleHUDOpacityFieldStillDecodes() throws {
        let json = """
        {"bundleIdentifier":"com.acme.app","appName":"App","mappings":[],"isEnabled":true,"hudOpacity":0.85}
        """.data(using: .utf8)!
        XCTAssertNoThrow(try JSONDecoder().decode(AppProfile.self, from: json))
    }

    func testLegacyPreferencesDecodeWithoutHUDHotkey() throws {
        let json = """
        {"globalToggleHotkey":{"keyCode":40,"modifiers":393216}}
        """.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(prefs.globalToggleHotkey?.keyCode, 40)
    }

    // MARK: - 键帽

    func testCapSymbolsSplitModifiersAndKey() {
        let caps = CGKeyCodeNames.capSymbols(for: 0x28, modifiers: 0x40000 | 0x20000)
        XCTAssertEqual(caps, ["⌃", "⇧", "K"])
    }

    func testCapSymbolsUseCompactKeyNames() {
        XCTAssertEqual(CGKeyCodeNames.capSymbols(for: 0x31, modifiers: 0), ["space"])
        XCTAssertEqual(CGKeyCodeNames.capSymbols(for: 0x24, modifiers: 0), ["↩"])
        XCTAssertEqual(CGKeyCodeNames.shortKeyName(for: 0x7E), "↑")
    }
}

// MARK: - 宏重复模式（回归：输入次数会把分段控件带着跳）

@MainActor
final class MacroRepeatModeTests: XCTestCase {
    private func makeViewModel(repeatCount: Int) -> MacroEditorViewModel {
        let profile = AppProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let macro = MacroAction(
            label: "M", triggerType: .keyboard, keyCode: 0x7A,
            repeatCount: repeatCount,
            steps: [MacroStep(position: .inline(relativeX: 1, relativeY: 2, referenceWidth: nil, referenceHeight: nil))]
        )
        return MacroEditorViewModel(profile: profile, existingMacro: macro)
    }

    /// 核心回归：模式是**独立状态**，改次数不该把模式带跑
    func testTypingCountDoesNotChangeMode() {
        let vm = makeViewModel(repeatCount: 50)
        XCTAssertEqual(vm.repeatMode, .count)

        vm.repeatCountText = 1        // 输入过程中的中间态
        XCTAssertEqual(vm.repeatMode, .count, "改次数不能把模式切成「单次」")

        vm.repeatCountText = 10
        XCTAssertEqual(vm.repeatMode, .count)
    }

    func testInfiniteModeKeepsCountForLaterUse() {
        let vm = makeViewModel(repeatCount: 50)
        vm.repeatMode = .infinite
        XCTAssertEqual(vm.repeatCountText, 50, "切到无限不该抹掉已输入的次数")
        vm.repeatMode = .count
        XCTAssertEqual(vm.repeatCountText, 50)
    }

    func testLoadingEachRepeatCountPicksRightMode() {
        XCTAssertEqual(makeViewModel(repeatCount: 0).repeatMode, .infinite)
        XCTAssertEqual(makeViewModel(repeatCount: 1).repeatMode, .once)
        XCTAssertEqual(makeViewModel(repeatCount: 2).repeatMode, .count)
        XCTAssertEqual(makeViewModel(repeatCount: 500).repeatMode, .count)
    }

    func testModeAndCountMapBackToStoredRepeatCount() {
        XCTAssertEqual(MacroEditorViewModel.repeatCount(mode: .infinite, count: 10), 0)
        XCTAssertEqual(MacroEditorViewModel.repeatCount(mode: .once, count: 10), 1)
        XCTAssertEqual(MacroEditorViewModel.repeatCount(mode: .count, count: 10), 10)
        // 「N 次」模式下 N 至少是 2，否则语义上就是「单次」
        XCTAssertEqual(MacroEditorViewModel.repeatCount(mode: .count, count: 1), 2)
    }

}
