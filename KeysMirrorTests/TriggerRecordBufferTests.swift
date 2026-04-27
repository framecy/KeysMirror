import XCTest
import CoreGraphics
@testable import KeysMirror

@MainActor
final class TriggerRecordBufferTests: XCTestCase {
    override func tearDown() async throws {
        AppLogger.shared.clearTriggerRecords()
        try await super.tearDown()
    }

    func testRecordTriggerInsertsAtFront() {
        AppLogger.shared.recordTrigger(label: "A", trigger: "Q", clickPoint: .init(x: 1, y: 2), blockInput: true)
        AppLogger.shared.recordTrigger(label: "B", trigger: "W", clickPoint: .init(x: 3, y: 4), blockInput: false)
        XCTAssertEqual(AppLogger.shared.triggerRecords.count, 2)
        XCTAssertEqual(AppLogger.shared.triggerRecords[0].mappingLabel, "B", "最新一条应在最前")
        XCTAssertEqual(AppLogger.shared.triggerRecords[1].mappingLabel, "A")
        XCTAssertTrue(AppLogger.shared.triggerRecords[1].blockInput)
        XCTAssertEqual(AppLogger.shared.triggerRecords[0].clickPoint, CGPoint(x: 3, y: 4))
    }

    func testRingBufferCapsAtMaxAndKeepsNewest() {
        for i in 0..<150 {
            AppLogger.shared.recordTrigger(label: "L\(i)", trigger: "K", clickPoint: .zero, blockInput: false)
        }
        XCTAssertEqual(AppLogger.shared.triggerRecords.count, 100, "上限 100，超出后丢最旧")
        XCTAssertEqual(AppLogger.shared.triggerRecords[0].mappingLabel, "L149", "最新仍在最前")
        XCTAssertEqual(AppLogger.shared.triggerRecords[99].mappingLabel, "L50", "最旧应是 L50（150 - 100）")
    }

    func testClearEmptiesBuffer() {
        AppLogger.shared.recordTrigger(label: "X", trigger: "K", clickPoint: .zero, blockInput: false)
        XCTAssertFalse(AppLogger.shared.triggerRecords.isEmpty)
        AppLogger.shared.clearTriggerRecords()
        XCTAssertTrue(AppLogger.shared.triggerRecords.isEmpty)
    }
}
