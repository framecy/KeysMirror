import XCTest
@testable import KeysMirror

final class CoordinateConverterTests: XCTestCase {
    func testAbsolutePointUsesWindowOriginPlusRelativeOffsets() {
        let frame = CGRect(x: 320, y: 200, width: 800, height: 600)

        let point = CoordinateConverter.absolutePoint(relativeX: 100, relativeY: 50, in: frame)

        XCTAssertEqual(point.x, 420)
        XCTAssertEqual(point.y, 250)
    }

    func testRelativePointProducesOffsetsInsideWindow() {
        let frame = CGRect(x: 320, y: 200, width: 800, height: 600)

        let point = CoordinateConverter.relativePoint(from: CGPoint(x: 500, y: 430), in: frame)

        XCTAssertEqual(point?.x, 180)
        XCTAssertEqual(point?.y, 230)
    }

    func testRelativePointRejectsClicksOutsideWindow() {
        let frame = CGRect(x: 320, y: 200, width: 800, height: 600)

        XCTAssertNil(CoordinateConverter.relativePoint(from: CGPoint(x: 100, y: 100), in: frame))
    }
}
