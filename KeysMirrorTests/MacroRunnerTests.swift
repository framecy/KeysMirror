import XCTest
@testable import KeysMirror

@MainActor
final class MacroRunnerTests: XCTestCase {
    // MARK: - computeStepCount

    func testComputeStepCountOneIsOne() {
        XCTAssertEqual(MacroRunner.computeStepCount(repeatCount: 1), 1)
    }

    func testComputeStepCountFiveIsFive() {
        XCTAssertEqual(MacroRunner.computeStepCount(repeatCount: 5), 5)
    }

    func testComputeStepCountZeroIsInfinite() {
        XCTAssertEqual(MacroRunner.computeStepCount(repeatCount: 0), Int.max)
    }

    func testComputeStepCountNegativeFloorsToOne() {
        // 负数理论上不该出现，但保底返回 1 而不是 0
        XCTAssertEqual(MacroRunner.computeStepCount(repeatCount: -3), 1)
    }

    // MARK: - resolvePosition

    func testResolvePositionInlineUsesEmbeddedCoordinates() throws {
        let step = MacroStep(
            position: .inline(relativeX: 100, relativeY: 50, referenceWidth: nil, referenceHeight: nil)
        )
        let profile = AppProfile(bundleIdentifier: "com.acme.app", appName: "App")

        let p = try XCTUnwrap(MacroRunner.resolvePosition(step: step, profile: profile, windowSize: CGSize(width: 800, height: 600)))
        XCTAssertEqual(p.x, 100, accuracy: 0.001)
        XCTAssertEqual(p.y, 50, accuracy: 0.001)
    }

    func testResolvePositionMappingUsesReferencedMapping() throws {
        let mapping = KeyMapping(
            keyCode: 0, modifiers: 0,
            relativeX: 200, relativeY: 100,
            label: "M",
            referenceWidth: nil, referenceHeight: nil
        )
        let profile = AppProfile(
            bundleIdentifier: "com.acme.app",
            appName: "App",
            mappings: [mapping]
        )
        let step = MacroStep(position: .mapping(mapping.id))

        let p = try XCTUnwrap(MacroRunner.resolvePosition(step: step, profile: profile, windowSize: CGSize(width: 1000, height: 1000)))
        XCTAssertEqual(p.x, 200, accuracy: 0.001)
        XCTAssertEqual(p.y, 100, accuracy: 0.001)
    }

    func testResolvePositionMappingMissingReturnsNil() {
        let profile = AppProfile(bundleIdentifier: "com.acme.app", appName: "App")
        let step = MacroStep(position: .mapping(UUID()))
        XCTAssertNil(MacroRunner.resolvePosition(step: step, profile: profile, windowSize: CGSize(width: 800, height: 600)))
    }

    func testResolvePositionInlineWithReferenceScales() throws {
        // 录制时窗口 800x600，点 (400, 300)；运行时窗口缩到 400x300 → 点应缩到 (200, 150)
        let step = MacroStep(
            position: .inline(relativeX: 400, relativeY: 300, referenceWidth: 800, referenceHeight: 600)
        )
        let profile = AppProfile(bundleIdentifier: "com.acme.app", appName: "App")

        let p = try XCTUnwrap(MacroRunner.resolvePosition(step: step, profile: profile, windowSize: CGSize(width: 400, height: 300)))
        XCTAssertEqual(p.x, 200, accuracy: 0.001)
        XCTAssertEqual(p.y, 150, accuracy: 0.001)
    }
}
