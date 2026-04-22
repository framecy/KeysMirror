import XCTest
@testable import KeysMirror

@MainActor
final class MappingStoreTests: XCTestCase {
    func testStorePersistsProfilesAndMappings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        let profile = try XCTUnwrap(store.profiles.first)
        let mapping = KeyMapping(keyCode: 40, modifiers: 0, relativeX: 100, relativeY: 50, label: "Attack")
        store.addMapping(mapping, to: profile)

        let reloadedStore = MappingStore(fileURL: fileURL)
        reloadedStore.load()

        let reloadedProfile = try XCTUnwrap(reloadedStore.profiles.first)
        XCTAssertEqual(reloadedProfile.bundleIdentifier, "com.apple.TextEdit")
        XCTAssertEqual(reloadedProfile.mappings.first?.label, "Attack")
        XCTAssertEqual(reloadedProfile.mappings.first?.relativeX, 100)
        XCTAssertEqual(reloadedProfile.mappings.first?.relativeY, 50)
    }

    func testCorruptMappingsFileIsBackedUpInsteadOfWiped() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("mappings.json")

        let garbage = Data("{ this is not valid json".utf8)
        try garbage.write(to: fileURL)

        let store = MappingStore(fileURL: fileURL)
        XCTAssertTrue(store.profiles.isEmpty)

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("mappings.json.bak.") }
        XCTAssertEqual(backups.count, 1, "解析失败的文件必须保留备份，不能被静默覆盖")

        // 原文件已被搬走，新写入不会污染备份
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExportImportRoundTripMergesByBundleId() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store1 = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        store1.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let p1 = store1.profiles[0]
        store1.addMapping(KeyMapping(keyCode: 12, modifiers: 0, relativeX: 10, relativeY: 20, label: "Q"), to: p1)

        let exported = try store1.exportData(for: store1.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store2 = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        // 预先放一个不同 bundleId 的配置
        store2.addProfile(bundleIdentifier: "com.other.app", appName: "Other")
        // 再放一个相同 bundleId 的旧配置（应被覆盖）
        store2.addProfile(bundleIdentifier: "com.acme.game", appName: "OldGame")

        let imported = try store2.importProfiles(from: exported, mode: .merge)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store2.profiles.count, 2, "merge 应覆盖同 bundleId，不应新增")

        let merged = try XCTUnwrap(store2.profiles.first { $0.bundleIdentifier == "com.acme.game" })
        XCTAssertEqual(merged.appName, "Game")
        XCTAssertEqual(merged.mappings.first?.label, "Q")
    }

    func testImportAddAsNewAlwaysAppends() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store1 = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        store1.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let exported = try store1.exportData(for: store1.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store2 = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        store2.addProfile(bundleIdentifier: "com.acme.game", appName: "Existing")

        let imported = try store2.importProfiles(from: exported, mode: .addAsNew)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store2.profiles.count, 2, "addAsNew 即使 bundleId 冲突也应追加")
    }

    func testImportAcceptsBareProfileArrayForBackwardCompat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = MappingStore(fileURL: dir.appendingPathComponent("mappings.json"))

        let bare = [AppProfile(bundleIdentifier: "com.legacy.app", appName: "Legacy")]
        let encoder = JSONEncoder()
        let data = try encoder.encode(bare)

        let imported = try store.importProfiles(from: data, mode: .merge)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store.profiles.first?.bundleIdentifier, "com.legacy.app")
    }

    func testDuplicateTriggerIsDetected() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.apple.TextEdit", appName: "TextEdit")
        let profile = store.profiles[0]
        let existing = KeyMapping(keyCode: 12, modifiers: 0, relativeX: 10, relativeY: 10, label: "Q")
        store.addMapping(existing, to: profile)

        let dup = KeyMapping(keyCode: 12, modifiers: 0, relativeX: 99, relativeY: 99, label: "Other")
        XCTAssertTrue(store.hasDuplicateTrigger(dup, in: profile))

        // 不同修饰键不算重复
        let withMod = KeyMapping(keyCode: 12, modifiers: 0x100000, relativeX: 0, relativeY: 0, label: "Cmd+Q")
        XCTAssertFalse(store.hasDuplicateTrigger(withMod, in: profile))

        // 编辑自身不算重复
        XCTAssertFalse(store.hasDuplicateTrigger(existing, in: profile, excludingId: existing.id))
    }

    // MARK: - Macros

    func testMacroCRUDPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let profile = store.profiles[0]

        let macro = MacroAction(
            label: "日常",
            triggerType: .keyboard,
            keyCode: 122,
            repeatCount: 3,
            steps: [
                MacroStep(delaySeconds: 0, position: .inline(relativeX: 100, relativeY: 100, referenceWidth: 800, referenceHeight: 600)),
                MacroStep(delaySeconds: 2, position: .inline(relativeX: 200, relativeY: 200, referenceWidth: 800, referenceHeight: 600))
            ]
        )
        store.addMacro(macro, to: profile)

        let reloaded = MappingStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.profiles.first?.macros.count, 1)
        XCTAssertEqual(reloaded.profiles.first?.macros.first?.label, "日常")
        XCTAssertEqual(reloaded.profiles.first?.macros.first?.steps.count, 2)

        // update
        var updated = reloaded.profiles[0].macros[0]
        updated.label = "日常 v2"
        reloaded.updateMacro(updated, in: reloaded.profiles[0])

        let reloaded2 = MappingStore(fileURL: fileURL)
        XCTAssertEqual(reloaded2.profiles[0].macros.first?.label, "日常 v2")

        // delete
        reloaded2.deleteMacro(reloaded2.profiles[0].macros[0], from: reloaded2.profiles[0])
        let reloaded3 = MappingStore(fileURL: fileURL)
        XCTAssertTrue(reloaded3.profiles[0].macros.isEmpty)
    }

    func testTriggerConflictAcrossMappingAndMacro() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("mappings.json")
        let store = MappingStore(fileURL: fileURL)

        store.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let profile = store.profiles[0]

        // 已有 mapping 占用 F1
        store.addMapping(KeyMapping(keyCode: 122, modifiers: 0, relativeX: 0, relativeY: 0, label: "Click"), to: profile)

        // 新建宏想用 F1 → 冲突
        XCTAssertTrue(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 122, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))

        // 不同 trigger 不冲突
        XCTAssertFalse(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 123, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))

        // 已有宏占用 F2，再来一条同 trigger 的宏：编辑自身不冲突，新增冲突
        let macro = MacroAction(label: "M", triggerType: .keyboard, keyCode: 120, steps: [
            MacroStep(position: .inline(relativeX: 0, relativeY: 0, referenceWidth: nil, referenceHeight: nil))
        ])
        store.addMacro(macro, to: profile)

        XCTAssertTrue(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 120, modifiers: 0, mouseButtonNumber: nil,
            in: profile
        ))
        XCTAssertFalse(store.hasDuplicateTrigger(
            triggerType: .keyboard, keyCode: 120, modifiers: 0, mouseButtonNumber: nil,
            in: profile,
            excludingMacroId: macro.id
        ))
    }

    func testExportImportPreservesMacros() throws {
        let dir1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store1 = MappingStore(fileURL: dir1.appendingPathComponent("mappings.json"))
        store1.addProfile(bundleIdentifier: "com.acme.game", appName: "Game")
        let profile1 = store1.profiles[0]
        store1.addMacro(MacroAction(
            label: "测试宏",
            triggerType: .keyboard,
            keyCode: 12,
            repeatCount: 5,
            steps: [
                MacroStep(delaySeconds: 1.5, position: .inline(relativeX: 50, relativeY: 60, referenceWidth: 1024, referenceHeight: 768))
            ]
        ), to: profile1)

        let exported = try store1.exportData(for: store1.profiles)

        let dir2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store2 = MappingStore(fileURL: dir2.appendingPathComponent("mappings.json"))
        let imported = try store2.importProfiles(from: exported, mode: .merge)
        XCTAssertEqual(imported, 1)

        let restored = try XCTUnwrap(store2.profiles.first)
        XCTAssertEqual(restored.macros.count, 1)
        XCTAssertEqual(restored.macros.first?.label, "测试宏")
        XCTAssertEqual(restored.macros.first?.steps.first?.delaySeconds, 1.5)
    }
}
