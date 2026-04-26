import XCTest
@testable import KeysMirror

/// v1.6.2 新增：连续触发节流。防止用户快速连按导致 iOS-on-Mac 游戏的输入队列被灌爆，
/// 进而 UI 假死。35ms 窗口经验值——60fps 单帧 16ms，留两帧给游戏喘气，
/// 远低于人类无意识连击的物理上限（5 次/秒 = 200ms 间隔）。
final class TriggerThrottleTests: XCTestCase {
    func testFirstFireAlwaysAllowed() {
        var t = TriggerThrottle()
        XCTAssertTrue(t.shouldFire(UUID(), now: 1.0))
    }

    func testRepeatWithinWindowDropped() {
        var t = TriggerThrottle()
        let id = UUID()
        XCTAssertTrue(t.shouldFire(id, now: 1.000))
        XCTAssertFalse(t.shouldFire(id, now: 1.010), "10ms 内应被节流")
        XCTAssertFalse(t.shouldFire(id, now: 1.034), "34ms 内（< 35ms 窗口）仍应被节流")
    }

    func testRepeatAfterWindowAllowed() {
        var t = TriggerThrottle()
        let id = UUID()
        XCTAssertTrue(t.shouldFire(id, now: 1.000))
        // 用 1.040 而非 1.035 以避开 1.035-1.000 的 FP 精度毛刺
        XCTAssertTrue(t.shouldFire(id, now: 1.040), "超过窗口应放行")
        XCTAssertTrue(t.shouldFire(id, now: 1.200), "远超窗口应放行")
    }

    func testDifferentIdsAreIndependent() {
        var t = TriggerThrottle()
        let a = UUID()
        let b = UUID()
        XCTAssertTrue(t.shouldFire(a, now: 1.000))
        XCTAssertTrue(t.shouldFire(b, now: 1.000), "不同 mapping 互不影响")
        XCTAssertFalse(t.shouldFire(a, now: 1.005))
        XCTAssertFalse(t.shouldFire(b, now: 1.005))
    }

    func testCustomIntervalRespected() {
        var t = TriggerThrottle()
        t.intervalSeconds = 0.100
        let id = UUID()
        XCTAssertTrue(t.shouldFire(id, now: 1.000))
        XCTAssertFalse(t.shouldFire(id, now: 1.080), "100ms 窗口下，80ms 仍应被吃")
        XCTAssertTrue(t.shouldFire(id, now: 1.100))
    }

    func testRapidBurstThenIdleResumes() {
        // 模拟用户在 35ms 窗内连击 4 下（10ms / 20ms / 30ms 都被吃），停手后正常触发应通过
        var t = TriggerThrottle()
        let id = UUID()
        XCTAssertTrue(t.shouldFire(id, now: 1.000))
        for i in 1..<4 {
            XCTAssertFalse(t.shouldFire(id, now: 1.000 + Double(i) * 0.010))
        }
        XCTAssertTrue(t.shouldFire(id, now: 1.500), "停手后下一次应正常通过")
    }

    func testResetForTesting() {
        var t = TriggerThrottle()
        let id = UUID()
        XCTAssertTrue(t.shouldFire(id, now: 1.000))
        XCTAssertFalse(t.shouldFire(id, now: 1.005))
        t.resetForTesting()
        XCTAssertTrue(t.shouldFire(id, now: 1.005), "reset 后应当像第一次触发")
    }
}
