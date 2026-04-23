import XCTest
import AppKit
@testable import KeysMirror

@MainActor
final class ClickSimulatorTests: XCTestCase {
    /// ClickSimulator 是单例；每个用例后还原 provider 与缓存，避免污染相邻测试。
    private let defaultProvider: (URL) -> NSDictionary? = { NSDictionary(contentsOf: $0) }

    override func tearDown() async throws {
        await MainActor.run {
            ClickSimulator.shared.clearNativeCacheForTesting()
            ClickSimulator.shared.infoPlistProvider = defaultProvider
        }
        try await super.tearDown()
    }

    func testInfoPlistRequiresIPhoneOSMarksAppNonNative() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        ClickSimulator.shared.infoPlistProvider = { _ in
            ["LSRequiresIPhoneOS": true] as NSDictionary
        }
        XCTAssertFalse(ClickSimulator.shared.isNativeMacApp(NSRunningApplication.current))
    }

    func testMissingPlistFallsBackToBundleIdSuffixHeuristic() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        ClickSimulator.shared.infoPlistProvider = { _ in nil }
        // 测试 host bundleId 不以 .ios 结尾 → 视为原生
        XCTAssertTrue(ClickSimulator.shared.isNativeMacApp(NSRunningApplication.current))
    }

    func testSameBundleIdHitsCacheAndSkipsProvider() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        var providerCalls = 0
        ClickSimulator.shared.infoPlistProvider = { _ in
            providerCalls += 1
            return ["LSRequiresIPhoneOS": false] as NSDictionary
        }

        _ = ClickSimulator.shared.isNativeMacApp(NSRunningApplication.current)
        _ = ClickSimulator.shared.isNativeMacApp(NSRunningApplication.current)
        _ = ClickSimulator.shared.isNativeMacApp(NSRunningApplication.current)

        XCTAssertEqual(providerCalls, 1, "同一 bundleId 第二次起应命中缓存，不再读 plist")
    }

    func testTerminateNotificationInvalidatesCacheEntry() async {
        ClickSimulator.shared.clearNativeCacheForTesting()
        var providerCalls = 0
        ClickSimulator.shared.infoPlistProvider = { _ in
            providerCalls += 1
            return ["LSRequiresIPhoneOS": false] as NSDictionary
        }

        let app = NSRunningApplication.current
        _ = ClickSimulator.shared.isNativeMacApp(app)
        XCTAssertEqual(providerCalls, 1)

        // 模拟 didTerminate：notification 由 NSWorkspace 在 main queue 发，
        // observer 内部再 hop 到 MainActor 异步清空，需要让 run loop 跑一拍
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app]
        )
        // 让 Task { @MainActor in ... } 排到队列后再继续
        try? await Task.sleep(nanoseconds: 50_000_000)

        _ = ClickSimulator.shared.isNativeMacApp(app)
        XCTAssertEqual(providerCalls, 2, "didTerminate 后同 bundleId 应重新查询")
    }
}
