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

    // MARK: - CGWindowList 兜底（AX 不应答的 app，如部分 iOS-on-Mac 游戏）

    /// 造一条 CGWindowListCopyWindowInfo 风格的记录。
    private func windowInfo(pid: pid_t, layer: Int, bounds: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds) as NSDictionary,
        ]
    }

    func testMainWindowFramePicksLargestOwnedWindow() {
        let game = CGRect(x: 100, y: 80, width: 1920, height: 1080)
        let infos = [
            // 输入法候选框这类小窗口可能排在主窗口**前面**，所以不能取「最靠前」
            windowInfo(pid: 42, layer: 0, bounds: CGRect(x: 300, y: 300, width: 200, height: 140)),
            windowInfo(pid: 42, layer: 0, bounds: game),
        ]

        XCTAssertEqual(
            WindowLocator.mainWindowFrame(fromWindowList: infos, ownedBy: 42),
            game,
            "同一进程有多个窗口时应取面积最大的那个（游戏画面）"
        )
    }

    func testMainWindowFrameIgnoresOtherProcesses() {
        let mine = CGRect(x: 0, y: 0, width: 800, height: 600)
        let infos = [
            windowInfo(pid: 99, layer: 0, bounds: CGRect(x: 0, y: 0, width: 3840, height: 2160)),
            windowInfo(pid: 42, layer: 0, bounds: mine),
        ]

        XCTAssertEqual(
            WindowLocator.mainWindowFrame(fromWindowList: infos, ownedBy: 42),
            mine,
            "别的进程的窗口再大也不能选中"
        )
    }

    func testMainWindowFrameIgnoresNonZeroLayerAndTinyWindows() {
        let infos = [
            // layer != 0：菜单 / 悬浮窗 / 状态栏，不是可点击的主画面
            windowInfo(pid: 42, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            // 小于最小边长：提示气泡 / 候选框
            windowInfo(pid: 42, layer: 0, bounds: CGRect(x: 10, y: 10, width: 90, height: 40)),
        ]

        XCTAssertNil(
            WindowLocator.mainWindowFrame(fromWindowList: infos, ownedBy: 42),
            "非 layer 0 与过小窗口均不得当作主窗口"
        )
    }

    func testMainWindowFrameReturnsNilWhenProcessHasNoWindow() {
        let infos = [windowInfo(pid: 7, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))]

        XCTAssertNil(
            WindowLocator.mainWindowFrame(fromWindowList: infos, ownedBy: 42),
            "目标进程没有在屏窗口时应返回 nil（最小化 / 已退出）"
        )
    }
}
