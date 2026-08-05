import XCTest
@testable import KeysMirror

@MainActor
final class MacroSequenceRecorderTests: XCTestCase {
    private func sample(
        x: CGFloat,
        y: CGFloat,
        elapsed: TimeInterval,
        clickState: Int = 1,
        size: CGSize = CGSize(width: 800, height: 600)
    ) -> SequenceSample {
        SequenceSample(
            relativePoint: CGPoint(x: x, y: y),
            referenceSize: size,
            elapsed: elapsed,
            clickState: clickState
        )
    }

    func testEmptySamplesProduceNoSteps() {
        XCTAssertTrue(MacroSequenceRecorder.buildSteps(from: []).isEmpty)
    }

    func testFirstStepHasZeroDelay() throws {
        let steps = MacroSequenceRecorder.buildSteps(from: [sample(x: 10, y: 20, elapsed: 3.5)])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].delaySeconds, 0)
        XCTAssertEqual(steps[0].clickCount, 1)

        guard case .inline(let x, let y, let refW, let refH) = steps[0].position else {
            return XCTFail("应该录成 inline 坐标")
        }
        XCTAssertEqual(x, 10)
        XCTAssertEqual(y, 20)
        XCTAssertEqual(refW, 800)
        XCTAssertEqual(refH, 600)
    }

    func testDelayIsGapBetweenConsecutiveClicks() {
        let steps = MacroSequenceRecorder.buildSteps(from: [
            sample(x: 10, y: 10, elapsed: 1.0),
            sample(x: 300, y: 200, elapsed: 3.25),
            sample(x: 500, y: 400, elapsed: 4.0),
        ])
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].delaySeconds, 0)
        XCTAssertEqual(steps[1].delaySeconds, 2.25, accuracy: 0.0001)
        XCTAssertEqual(steps[2].delaySeconds, 0.75, accuracy: 0.0001)
    }

    func testDoubleClickMergesIntoOneStepWithClickCountTwo() {
        let steps = MacroSequenceRecorder.buildSteps(from: [
            sample(x: 100, y: 100, elapsed: 0),
            sample(x: 101, y: 99, elapsed: 0.12, clickState: 2),
        ])
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].clickCount, 2)
    }

    func testFarApartClicksAreSeparateStepsEvenWhenFast() {
        let steps = MacroSequenceRecorder.buildSteps(from: [
            sample(x: 100, y: 100, elapsed: 0),
            sample(x: 400, y: 100, elapsed: 0.05),
        ])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].clickCount, 1)
        XCTAssertEqual(steps[1].clickCount, 1)
    }

    func testSlowRepeatAtSamePointIsSeparateStep() {
        let steps = MacroSequenceRecorder.buildSteps(from: [
            sample(x: 100, y: 100, elapsed: 0),
            sample(x: 100, y: 100, elapsed: 2.0),
        ])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[1].delaySeconds, 2.0, accuracy: 0.0001)
    }

    func testDelayAfterMergedMultiClickMeasuresFromFirstClickOfPreviousStep() {
        // 双击（0.0 / 0.15）后再点一次（1.0）：新步骤的延迟以上一步的**首次**点击为基准
        let steps = MacroSequenceRecorder.buildSteps(from: [
            sample(x: 100, y: 100, elapsed: 0),
            sample(x: 100, y: 100, elapsed: 0.15, clickState: 2),
            sample(x: 500, y: 300, elapsed: 1.0),
        ])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].clickCount, 2)
        XCTAssertEqual(steps[1].delaySeconds, 1.0, accuracy: 0.0001)
    }

    // MARK: - clickCount 兼容性

    func testLegacyStepWithoutClickCountDecodesToOne() throws {
        let json = """
        {"id":"\(UUID().uuidString)","delaySeconds":1,"position":{"type":"inline","relativeX":10,"relativeY":20}}
        """.data(using: .utf8)!
        let step = try JSONDecoder().decode(MacroStep.self, from: json)
        XCTAssertEqual(step.clickCount, 1)
    }

    func testClickCountRoundTrips() throws {
        let step = MacroStep(
            delaySeconds: 0.5,
            position: .inline(relativeX: 1, relativeY: 2, referenceWidth: nil, referenceHeight: nil),
            clickCount: 3
        )
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(MacroStep.self, from: data)
        XCTAssertEqual(decoded.clickCount, 3)
    }
}
