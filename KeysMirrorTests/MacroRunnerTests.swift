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

    // MARK: - applyDrift (区域漂移)

    func testDriftZeroReturnsExactPoint() {
        let base = CGPoint(x: 500, y: 400)
        let out = MacroRunner.applyDrift(toOffset: base, driftPercent: 0, windowSize: CGSize(width: 1920, height: 1080)) { _ in 1 }
        XCTAssertEqual(out, base, "driftPercent=0 必须精确命中录制点")
    }

    func testDriftAppliesPercentageOfWindowSize() {
        // 窗口 1920x1080，drift 1%，random 恒返回 +1（取满正方向）
        // → dx = 1920*0.01*1 = 19.2, dy = 1080*0.01*1 = 10.8
        let out = MacroRunner.applyDrift(
            toOffset: CGPoint(x: 500, y: 400),
            driftPercent: 1,
            windowSize: CGSize(width: 1920, height: 1080)
        ) { _ in 1 }
        XCTAssertEqual(out.x, 519.2, accuracy: 0.001)
        XCTAssertEqual(out.y, 410.8, accuracy: 0.001)
    }

    func testDriftNegativeDirection() {
        let out = MacroRunner.applyDrift(
            toOffset: CGPoint(x: 500, y: 400),
            driftPercent: 2,
            windowSize: CGSize(width: 1000, height: 1000)
        ) { _ in -1 }
        // dx = dy = 1000*0.02*(-1) = -20
        XCTAssertEqual(out.x, 480, accuracy: 0.001)
        XCTAssertEqual(out.y, 380, accuracy: 0.001)
    }

    func testDriftClampsToWindowBounds() {
        // 录制点贴着右下角，随机取满正方向 → 会越界 → 必须 clamp 回窗口内
        let out = MacroRunner.applyDrift(
            toOffset: CGPoint(x: 995, y: 995),
            driftPercent: 5,
            windowSize: CGSize(width: 1000, height: 1000)
        ) { _ in 1 }
        XCTAssertEqual(out.x, 1000, accuracy: 0.001)
        XCTAssertEqual(out.y, 1000, accuracy: 0.001)
        XCTAssertLessThanOrEqual(out.x, 1000)
        XCTAssertLessThanOrEqual(out.y, 1000)
    }

    func testDriftClampsAtZero() {
        let out = MacroRunner.applyDrift(
            toOffset: CGPoint(x: 3, y: 3),
            driftPercent: 5,
            windowSize: CGSize(width: 1000, height: 1000)
        ) { _ in -1 }
        XCTAssertEqual(out.x, 0, accuracy: 0.001)
        XCTAssertEqual(out.y, 0, accuracy: 0.001)
    }

    func testDriftStaysWithinBoxOverManyRandomSamples() {
        // 真随机采样 200 次：结果必须始终落在 ±drift 盒内并 clamp 在窗口内
        let base = CGPoint(x: 500, y: 500)
        let win = CGSize(width: 1000, height: 1000)
        let drift = 3.0
        let maxOff = win.width * drift / 100.0
        for _ in 0..<200 {
            let out = MacroRunner.applyDrift(toOffset: base, driftPercent: drift, windowSize: win)
            XCTAssertLessThanOrEqual(abs(out.x - base.x), maxOff + 0.001)
            XCTAssertLessThanOrEqual(abs(out.y - base.y), maxOff + 0.001)
            XCTAssertTrue((0...win.width).contains(out.x))
            XCTAssertTrue((0...win.height).contains(out.y))
        }
    }

    func testDriftIgnoredForZeroSizeWindow() {
        let base = CGPoint(x: 10, y: 10)
        let out = MacroRunner.applyDrift(toOffset: base, driftPercent: 5, windowSize: .zero) { _ in 1 }
        XCTAssertEqual(out, base, "窗口尺寸为 0 时不漂移，避免除零 / 无意义偏移")
    }
}
