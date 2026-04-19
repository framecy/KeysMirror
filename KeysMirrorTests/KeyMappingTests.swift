import XCTest
@testable import KeysMirror

final class KeyMappingTests: XCTestCase {
    func testAbsoluteOffsetWithoutReferenceUsesRawValues() {
        let mapping = KeyMapping(relativeX: 100, relativeY: 200, label: "legacy")

        let offset = mapping.absoluteOffset(in: CGSize(width: 1600, height: 1000))

        XCTAssertEqual(offset.x, 100)
        XCTAssertEqual(offset.y, 200)
    }

    func testAbsoluteOffsetScalesWhenReferenceIsPresent() {
        let mapping = KeyMapping(
            relativeX: 200,
            relativeY: 100,
            label: "scaled",
            referenceWidth: 800,
            referenceHeight: 600
        )

        // 窗口被放大 2 倍，点击位置等比放大
        let offset = mapping.absoluteOffset(in: CGSize(width: 1600, height: 1200))

        XCTAssertEqual(offset.x, 400)
        XCTAssertEqual(offset.y, 200)
    }

    func testDisplayShortcutForKeyboardUsesShortcutLabel() {
        let mapping = KeyMapping(
            keyCode: 0x28, // K
            modifiers: 0,
            triggerType: .keyboard,
            relativeX: 0,
            relativeY: 0,
            label: ""
        )
        XCTAssertFalse(mapping.displayShortcut.isEmpty)
        XCTAssertNotEqual(mapping.displayShortcut, "鼠标右键")
    }

    func testDisplayShortcutForMouseRight() {
        let mapping = KeyMapping(
            triggerType: .mouseRight,
            relativeX: 0,
            relativeY: 0,
            label: ""
        )
        XCTAssertEqual(mapping.displayShortcut, "鼠标右键")
    }

    func testDisplayShortcutForMouseOtherIncludesButtonNumber() {
        let mapping = KeyMapping(
            triggerType: .mouseOther,
            mouseButtonNumber: 4,
            relativeX: 0,
            relativeY: 0,
            label: ""
        )
        XCTAssertEqual(mapping.displayShortcut, "鼠标按键 4")
    }

    func testIsEnabledDefaultsToTrueOnLegacyDecode() throws {
        // 旧版本 mappings.json 没有 isEnabled 字段，应解码为 true 而非 false
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "keyCode": 12,
            "modifiers": 0,
            "triggerType": "keyboard",
            "relativeX": 100,
            "relativeY": 200,
            "label": "Q",
            "blockInput": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(KeyMapping.self, from: legacyJSON)
        XCTAssertTrue(decoded.isEnabled, "缺失 isEnabled 字段必须解码为 true 以避免老映射全部静默失效")
    }

    func testHasScaleReferenceReflectsRecordedSize() {
        let withRef = KeyMapping(relativeX: 0, relativeY: 0, label: "", referenceWidth: 800, referenceHeight: 600)
        XCTAssertTrue(withRef.hasScaleReference)

        let zeroRef = KeyMapping(relativeX: 0, relativeY: 0, label: "", referenceWidth: 0, referenceHeight: 0)
        XCTAssertFalse(zeroRef.hasScaleReference)

        let noRef = KeyMapping(relativeX: 0, relativeY: 0, label: "")
        XCTAssertFalse(noRef.hasScaleReference)
    }

    func testAbsoluteOffsetIgnoresReferenceWhenZero() {
        let mapping = KeyMapping(
            relativeX: 50,
            relativeY: 50,
            label: "broken",
            referenceWidth: 0,
            referenceHeight: 0
        )

        let offset = mapping.absoluteOffset(in: CGSize(width: 800, height: 600))

        XCTAssertEqual(offset.x, 50)
        XCTAssertEqual(offset.y, 50)
    }
}
