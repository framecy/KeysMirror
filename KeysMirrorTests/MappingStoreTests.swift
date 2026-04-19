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
}
