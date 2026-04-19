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
