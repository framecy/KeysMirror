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
