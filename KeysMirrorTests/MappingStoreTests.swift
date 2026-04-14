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
}
