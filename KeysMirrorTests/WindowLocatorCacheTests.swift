import XCTest
import AppKit
@testable import KeysMirror

@MainActor
final class WindowLocatorCacheTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run {
            WindowLocator.shared.frameProviderForTesting = nil
            WindowLocator.shared.clearFrameCacheForTesting()
        }
        try await super.tearDown()
    }

    func testCacheHitSkipsProviderOnSecondCall() {
        WindowLocator.shared.clearFrameCacheForTesting()
        var calls = 0
        WindowLocator.shared.frameProviderForTesting = { _ in
            calls += 1
            return CGRect(x: 10, y: 20, width: 100, height: 50)
        }

        _ = WindowLocator.shared.focusedWindowFrame(for: "com.acme.app")
        _ = WindowLocator.shared.focusedWindowFrame(for: "com.acme.app")
        _ = WindowLocator.shared.focusedWindowFrame(for: "com.acme.app")

        XCTAssertEqual(calls, 1, "同 bundleId 第二次起应命中 frame 缓存")
    }

    func testFocusedWindowFrameChangedNotificationInvalidatesCache() async {
        WindowLocator.shared.clearFrameCacheForTesting()
        let target = "com.acme.app"
        // 只统计我们关心的 bundleId 的查询；OverlayController 等订阅者也可能拉
        // 测试 host 自己的 bundleId，不应计入此用例。
        var calls = 0
        WindowLocator.shared.frameProviderForTesting = { bid in
            if bid == target { calls += 1 }
            return CGRect(x: 0, y: 0, width: 800, height: 600)
        }

        _ = WindowLocator.shared.focusedWindowFrame(for: target)
        XCTAssertEqual(calls, 1)

        NotificationCenter.default.post(name: .focusedWindowFrameChanged, object: nil)
        // observer 通过 Task { @MainActor in ... } 异步清缓存，需要让 run loop 跑一拍
        try? await Task.sleep(nanoseconds: 50_000_000)

        _ = WindowLocator.shared.focusedWindowFrame(for: target)
        XCTAssertEqual(calls, 2, ".focusedWindowFrameChanged 后应失效缓存触发新查询")
    }

    func testSwitchingBundleIdMissesCache() {
        WindowLocator.shared.clearFrameCacheForTesting()
        var calls = 0
        WindowLocator.shared.frameProviderForTesting = { _ in
            calls += 1
            return CGRect(x: 0, y: 0, width: 100, height: 100)
        }

        _ = WindowLocator.shared.focusedWindowFrame(for: "com.acme.first")
        _ = WindowLocator.shared.focusedWindowFrame(for: "com.acme.second")
        _ = WindowLocator.shared.focusedWindowFrame(for: "com.acme.first")

        XCTAssertEqual(calls, 3, "缓存只持有一对 (bundleId, frame)，切换 bundleId 必查 provider")
    }
}
