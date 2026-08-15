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

    /// PlayCover 安装的 iOS app 用扁平布局（Info.plist 在 bundle 根，不在 Contents/）。
    /// 只探 Contents/ 会读不到 plist，退化到 ".ios" 后缀后备判断——而 com.miHoYo.hkrpg
    /// 没有该后缀，就会被误判成原生 App 走 postToPid，点击对游戏完全无效。
    func testFlatIosBundleLayoutIsDetectedAsNonNative() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        var probed: [String] = []
        ClickSimulator.shared.infoPlistProvider = { url in
            probed.append(url.path)
            // 只有扁平布局那份存在
            guard !url.path.contains("/Contents/") else { return nil }
            return ["LSRequiresIPhoneOS": true] as NSDictionary
        }

        XCTAssertFalse(ClickSimulator.shared.isNativeMacApp(NSRunningApplication.current),
                       "扁平布局的 iOS bundle 必须判为非原生，走 session 层投递")
        XCTAssertTrue(probed.contains { $0.contains("/Contents/Info.plist") })
        XCTAssertTrue(probed.contains { $0.hasSuffix("Info.plist") && !$0.contains("/Contents/") },
                      "Contents/ 读不到时必须继续探 bundle 根目录")
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

    /// v1.6.2 新增：iOS-on-Mac 路径必须按 disassociate → post → warp → re-associate 的顺序，
    /// 否则会有一帧光标停在 click 点导致视觉抖动 / 连击「漂移」。
    ///
    /// hide / unhide 也必须出现在这条默认序列里并且**夹住**整段：先藏起来再动光标，
    /// 否则 disassociate 期间 Window Server 仍会把指针 sprite 挪到点击点，
    /// 中间那一帧真实可见——用户看到的就是「点一下鼠标闪一下」。
    func testIosOnMacClickFollowsCorrectCursorOrdering() {
        var calls: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { calls.append("save"); return CGPoint(x: 100, y: 100) },
            associate: { connected in calls.append("associate(\(connected ? "true" : "false"))") },
            warp: { p in calls.append("warp(\(Int(p.x)),\(Int(p.y)))") },
            post: { calls.append(Self.describe($0)) },
            hide: { calls.append("hide") },
            unhide: { calls.append("unhide") }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }   // 就地同步执行
        ClickSimulator.shared.sleepForDwell = { _ in calls.append("sleep") }
        defer { Self.restore() }

        // targetApp = nil → pid = 0 → 走 iOS-on-Mac 分支
        // 光标在 (100,100)、点击点在 (500,500)，距离远超隐藏阈值 → 必须走完整的隐藏序列
        ClickSimulator.shared.leftClick(at: CGPoint(x: 500, y: 500), targetApp: nil)

        XCTAssertEqual(calls, [
            "save",                 // 先存当前光标位置
            "hide",                 // 先隐藏再动它，否则中间那一帧的位移用户看得见
            "associate(false)",     // 再断开光标关联
            "moved(500,500)",       // 先让目标 app 把指针挪到点击点
            "down(500,500)",
            "sleep",                // 阻塞式停留，全程不让出 run loop
            "moved(500,500)",       // 抬起前再钉一次位置，防真实 move 挤进来把 up 带偏
            "up(500,500)",
            "moved(100,100)",       // 指针送回原处，不留 hover 态
            "warp(100,100)",        // 关键：先 warp 回原位
            "associate(true)",      // 然后才 re-associate，避免光标抖动
            "unhide"                // warp 完成后立刻恢复可见
        ])
    }

    /// 连击必须跑在**一次**光标序列里：原位只取一次，hide/warp/associate 各只做一次。
    ///
    /// 这是「鼠标箭头被拽到游戏里回不来」的直接成因。原先 MacroRunner 按 clickCount
    /// for 循环调 leftClick，每发都重新取一次原位；而连击是零间隔背靠背投递的，
    /// 第二发取原位时第一发的 warp 还没落定，取到的是已经被移到点击点的位置，
    /// 收尾就把光标「还原」到了点击点上。
    func testBurstClickSamplesCursorOriginExactlyOnce() {
        var calls: [String] = []
        var saveCount = 0
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: {
                saveCount += 1
                calls.append("save")
                // 模拟真实故障：第二次再取就会拿到已经被移过去的点击点
                return saveCount == 1 ? CGPoint(x: 100, y: 100) : CGPoint(x: 500, y: 500)
            },
            associate: { connected in calls.append("associate(\(connected ? "true" : "false"))") },
            warp: { p in calls.append("warp(\(Int(p.x)),\(Int(p.y)))") },
            post: { calls.append(Self.describe($0)) },
            hide: { calls.append("hide") },
            unhide: { calls.append("unhide") }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in calls.append("sleep") }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 500, y: 500), targetApp: nil, clickCount: 2)

        XCTAssertEqual(saveCount, 1, "原位只能取一次，取第二次就会拿到被移过去的位置")
        XCTAssertEqual(calls.filter { $0 == "hide" }.count, 1, "整段连击只藏一次光标")
        XCTAssertEqual(calls.filter { $0.hasPrefix("warp") }.count, 1, "只还原一次")
        XCTAssertEqual(calls.filter { $0 == "associate(false)" }.count, 1)
        XCTAssertEqual(calls, [
            "save",
            "hide",
            "associate(false)",
            "moved(500,500)", "down(500,500)", "sleep", "moved(500,500)", "up(500,500)",
            "moved(500,500)", "down(500,500)", "sleep", "moved(500,500)", "up(500,500)",
            "moved(100,100)",       // 送回的是**第一次**取到的真实原位
            "warp(100,100)",        // 还原到真实原位，而不是点击点
            "associate(true)",
            "unhide"
        ])
    }

    /// 连击在方案 A（原生 App / postToPid）下同样只投递一轮序列，且全程不碰光标。
    func testBurstClickOnPidPathRepeatsWithoutTouchingCursor() {
        var cursorCalls: [String] = []
        var pidPosts: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { cursorCalls.append("save"); return .zero },
            associate: { cursorCalls.append("associate(\($0))") },
            warp: { _ in cursorCalls.append("warp") },
            post: { cursorCalls.append(Self.describe($0)) },
            hide: { cursorCalls.append("hide") },
            unhide: { cursorCalls.append("unhide") }
        )
        ClickSimulator.shared.postToPid = { event, pid in pidPosts.append(Self.describe(event)) }
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: .zero, targetApp: NSRunningApplication.current, clickCount: 3)

        XCTAssertTrue(cursorCalls.isEmpty, "方案 A 全程不得触碰光标")
        XCTAssertEqual(pidPosts.count, 6, "3 连击 = 3 对 down/up")
    }

    /// clickCount 传 0 或负数时保底打一次，不能一次都不发。
    func testBurstClickClampsNonPositiveCount() {
        var pidPosts = 0
        ClickSimulator.shared.postToPid = { _, _ in pidPosts += 1 }
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: .zero, targetApp: NSRunningApplication.current, clickCount: 0)
        XCTAssertEqual(pidPosts, 2, "0 次也要保底发一对 down/up")
    }

    /// 光标已经在点击点附近时跳过隐藏。
    ///
    /// 隐藏本身是有代价的：指针会凭空消失整个 dwell（40ms）。当 sprite 的位移小到
    /// 肉眼分辨不出来时，为它藏光标 40ms 反而更难受——玩家每按一次映射键就看不见准星一下。
    /// 这条用例把「近距离不隐藏」的行为锁死，同时保证 associate/warp 这层保护仍在。
    func testNearbyClickSkipsCursorHiding() {
        var calls: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { CGPoint(x: 500, y: 500) },
            associate: { connected in calls.append("associate(\(connected ? "true" : "false"))") },
            warp: { _ in calls.append("warp") },
            post: { calls.append(Self.describe($0)) },
            hide: { calls.append("hide") },
            unhide: { calls.append("unhide") }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        // 距离 (5,5) → 远小于阈值
        ClickSimulator.shared.leftClick(at: CGPoint(x: 505, y: 505), targetApp: nil)

        XCTAssertFalse(calls.contains("hide"), "近距离点击不该隐藏光标——隐藏比位移更显眼")
        XCTAssertFalse(calls.contains("unhide"))
        XCTAssertEqual(calls.first, "associate(false)", "但冻结与还原这层保护必须仍在")
        XCTAssertEqual(calls.last, "associate(true)")
    }

    /// 刚好跨过阈值就必须恢复隐藏——阈值不能被无意中调大到「实际上永不隐藏」。
    func testClickBeyondThresholdStillHidesCursor() {
        var calls: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { .zero },
            associate: { _ in },
            warp: { _ in },
            post: { _ in },
            hide: { calls.append("hide") },
            unhide: { calls.append("unhide") }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        let justOver = ClickSimulator.cursorHideDistanceThreshold + 1
        ClickSimulator.shared.leftClick(at: CGPoint(x: justOver, y: 0), targetApp: nil)

        XCTAssertEqual(calls, ["hide", "unhide"])
    }

    // MARK: - 每应用按压时长

    func testDwellFallsBackToGlobalDefaultWhenUnset() {
        XCTAssertEqual(ClickSimulator.resolveDwell(nil), ClickSimulator.clickDwell)
    }

    func testDwellOverrideIsUsedWhenInRange() {
        XCTAssertEqual(ClickSimulator.resolveDwell(0.06), 0.06, accuracy: 0.0001)
    }

    /// mappings.json 是用户可以手改的纯文本，写进来的数不能直接信：
    /// 太小会让按帧轮询输入的游戏整个漏掉这次按下（点击静默失效），
    /// 太大会被目标 app 当成长按。两头都必须夹住。
    func testDwellOverrideIsClampedIntoSafeRange() {
        XCTAssertEqual(ClickSimulator.resolveDwell(0.001), ClickSimulator.dwellRange.lowerBound)
        XCTAssertEqual(ClickSimulator.resolveDwell(5.0), ClickSimulator.dwellRange.upperBound)
        XCTAssertEqual(ClickSimulator.resolveDwell(-1), ClickSimulator.dwellRange.lowerBound)
    }

    /// 覆盖值要真的传到那次阻塞停留上，而不是算完就丢。
    func testProfileDwellOverrideReachesTheActualSleep() {
        var sleptFor: TimeInterval?
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { .zero }, associate: { _ in }, warp: { _ in }, post: { _ in }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { sleptFor = $0 }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 300, y: 300), targetApp: nil, dwell: 0.08)
        XCTAssertEqual(try XCTUnwrap(sleptFor), 0.08, accuracy: 0.0001)
    }

    // MARK: - completion 回调

    /// 后台宏靠 completion 还原前台。它必须在整段投递**跑完之后**才触发，
    /// 且回到主线程——早一步还原，点击就会落在刚被切走的窗口上。
    func testCompletionFiresOnMainThreadAfterSequenceFinishes() {
        var calls: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { .zero },
            associate: { _ in },
            warp: { _ in },
            post: { calls.append(Self.describe($0)) }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        let done = expectation(description: "completion 被调用")
        ClickSimulator.shared.leftClick(at: CGPoint(x: 10, y: 20), targetApp: nil) {
            XCTAssertTrue(Thread.isMainThread, "completion 里要碰 AppKit，必须在主线程")
            XCTAssertEqual(calls.last, "moved(0,0)", "整段投递必须已经跑完")
            done.fulfill()
        }
        wait(for: [done], timeout: 1.0)
    }

    /// 方案 A（原生 macOS 应用）同样要回调 completion——两条路径的契约必须一致，
    /// 否则「目标是原生 app 的后台宏」会永远还原不了前台。
    func testCompletionAlsoFiresOnPostToPidPath() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        ClickSimulator.shared.infoPlistProvider = { _ in ["LSRequiresIPhoneOS": false] as NSDictionary }
        ClickSimulator.shared.postToPid = { _, _ in }
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        let done = expectation(description: "方案 A 也要回调 completion")
        ClickSimulator.shared.leftClick(at: .zero, targetApp: NSRunningApplication.current) {
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 1.0)
    }

    private static func restore() {
        ClickSimulator.shared.cursorOps = .system
        ClickSimulator.shared.runClickSequence = ClickSimulator.defaultRunner
        ClickSimulator.shared.sleepForDwell = { Thread.sleep(forTimeInterval: $0) }
        ClickSimulator.shared.forcePostToPidProvider = { false }
        ClickSimulator.shared.postToPid = { event, pid in event.postToPid(pid) }
    }

    // MARK: - 实验开关：强制 postToPid

    /// 投递方式的实验开关：只认这四个确切的名字，拼错 / 没设一律退回现状。
    /// 这个开关会改变事件的投递端口和窗口字段，误开会静默改掉所有 iOS-on-Mac 点击的行为。
    func testDeliveryModeFallsBackToStandard() {
        XCTAssertEqual(ClickSimulator.deliveryMode(environment: [:]), .standard)
        XCTAssertEqual(ClickSimulator.deliveryMode(environment: ["KEYSMIRROR_DELIVERY": "typo"]), .standard)
        XCTAssertEqual(ClickSimulator.deliveryMode(environment: ["KEYSMIRROR_DELIVERY": ""]), .standard)
        XCTAssertEqual(ClickSimulator.deliveryMode(environment: ["KEYSMIRROR_DELIVERY": "annotated"]), .annotated)
        XCTAssertEqual(ClickSimulator.deliveryMode(environment: ["KEYSMIRROR_DELIVERY": "windowID"]), .windowID)
        XCTAssertEqual(ClickSimulator.deliveryMode(environment: ["KEYSMIRROR_DELIVERY": "annotatedWindowID"]), .annotatedWindowID)
    }

    /// 各模式对应的投递端口与是否填窗口字段，必须锁死——这两条决定了实验测的到底是什么。
    func testDeliveryModeRouting() {
        XCTAssertEqual(ClickSimulator.DeliveryMode.standard.tapLocation, .cgSessionEventTap)
        XCTAssertEqual(ClickSimulator.DeliveryMode.windowID.tapLocation, .cgSessionEventTap)
        XCTAssertEqual(ClickSimulator.DeliveryMode.annotated.tapLocation, .cgAnnotatedSessionEventTap)
        XCTAssertEqual(ClickSimulator.DeliveryMode.annotatedWindowID.tapLocation, .cgAnnotatedSessionEventTap)

        XCTAssertFalse(ClickSimulator.DeliveryMode.standard.setsWindowID)
        XCTAssertFalse(ClickSimulator.DeliveryMode.annotated.setsWindowID)
        XCTAssertTrue(ClickSimulator.DeliveryMode.windowID.setsWindowID)
        XCTAssertTrue(ClickSimulator.DeliveryMode.annotatedWindowID.setsWindowID)
    }

    /// 生产默认必须是现状，否则一次误发布就会把所有用户的点击行为改掉。
    func testDeliveryModeDefaultsToStandardInThisProcess() {
        XCTAssertEqual(ClickSimulator.deliveryMode, .standard)
    }

    /// 实验开关必须只在显式设成 "1" 时才打开。误开的后果是所有 iOS-on-Mac 点击静默失效
    /// （事件进了进程但没人翻译成触摸），而且没有任何报错——所以宁可严格。
    func testForcePostToPidRequiresExplicitOptIn() {
        XCTAssertTrue(ClickSimulator.forcePostToPid(environment: ["KEYSMIRROR_FORCE_POSTTOPID": "1"]))
        XCTAssertFalse(ClickSimulator.forcePostToPid(environment: [:]),
                       "没设环境变量 → 正常走方案 B")
        for value in ["0", "", "true", "YES", "yes", "2"] {
            XCTAssertFalse(ClickSimulator.forcePostToPid(environment: ["KEYSMIRROR_FORCE_POSTTOPID": value]),
                           "只认 \"1\"，\"\(value)\" 不该打开实验路径")
        }
    }

    /// 开关打开时，本该走方案 B 的 iOS-on-Mac 应用必须改走方案 A：
    /// 全程不得触碰光标（这正是「指针不闪烁 + 不需要前台」的来源）。
    func testForcePostToPidRoutesIosAppThroughPidPath() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        ClickSimulator.shared.infoPlistProvider = { _ in ["LSRequiresIPhoneOS": true] as NSDictionary }

        var cursorCalls: [String] = []
        var pidPosts: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { cursorCalls.append("save"); return .zero },
            associate: { cursorCalls.append("associate(\($0))") },
            warp: { _ in cursorCalls.append("warp") },
            post: { cursorCalls.append(Self.describe($0)) },
            hide: { cursorCalls.append("hide") },
            unhide: { cursorCalls.append("unhide") }
        )
        ClickSimulator.shared.postToPid = { event, pid in pidPosts.append("\(Self.describe(event))@\(pid)") }
        ClickSimulator.shared.forcePostToPidProvider = { true }
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        let app = NSRunningApplication.current
        ClickSimulator.shared.leftClick(at: CGPoint(x: 300, y: 400), targetApp: app)

        XCTAssertTrue(cursorCalls.isEmpty, "方案 A 全程不得触碰光标，否则指针仍会闪")
        XCTAssertEqual(pidPosts, [
            "down(300,400)@\(app.processIdentifier)",
            "up(300,400)@\(app.processIdentifier)",
        ])
    }

    /// 开关关闭时行为不变——同一个 iOS 应用仍走方案 B，保证实验开关默认零影响。
    func testIosAppStillUsesSessionPathWhenSwitchOff() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        ClickSimulator.shared.infoPlistProvider = { _ in ["LSRequiresIPhoneOS": true] as NSDictionary }

        var cursorCalls: [String] = []
        var pidPosts: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { .zero },
            associate: { cursorCalls.append("associate(\($0))") },
            warp: { _ in cursorCalls.append("warp") },
            post: { cursorCalls.append(Self.describe($0)) },
            hide: { cursorCalls.append("hide") },
            unhide: { cursorCalls.append("unhide") }
        )
        ClickSimulator.shared.postToPid = { event, pid in pidPosts.append("\(Self.describe(event))@\(pid)") }
        ClickSimulator.shared.forcePostToPidProvider = { false }
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 300, y: 400), targetApp: NSRunningApplication.current)

        XCTAssertTrue(pidPosts.isEmpty, "开关关闭时不应走 postToPid")
        XCTAssertEqual(cursorCalls.first, "hide")
        XCTAssertEqual(cursorCalls.last, "unhide")
    }

    /// 开关不得影响原生 macOS 应用——它们本来就走方案 A。
    func testNativeAppUnaffectedBySwitch() {
        ClickSimulator.shared.clearNativeCacheForTesting()
        ClickSimulator.shared.infoPlistProvider = { _ in ["LSRequiresIPhoneOS": false] as NSDictionary }

        var pidPosts = 0
        ClickSimulator.shared.postToPid = { _, _ in pidPosts += 1 }
        ClickSimulator.shared.forcePostToPidProvider = { false }
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 1, y: 2), targetApp: NSRunningApplication.current)
        XCTAssertEqual(pidPosts, 2, "原生应用无论开关如何都走 postToPid")
    }

    /// PlayCover 等 iOS-on-Mac 运行时靠**鼠标移动事件流**维护指针位置，再据此合成 UITouch；
    /// 既不查系统光标，也不看 mouseDown 自带的坐标。所以 mouseDown 前必须先发 mouseMoved，
    /// 否则触摸落在旧位置上，点击打空（实测：崩坏：星穹铁道无 mouseMoved 时完全无响应）。
    func testMouseMovedPrecedesMouseDownAtSamePoint() {
        var calls: [String] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { CGPoint(x: 10, y: 20) },
            associate: { _ in },
            warp: { _ in },
            post: { calls.append(Self.describe($0)) }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 777, y: 888), targetApp: nil)

        XCTAssertEqual(calls, [
            "moved(777,888)",   // mouseDown 之前必须先发同点的 mouseMoved
            "down(777,888)",
            "moved(777,888)",   // 抬起前重申位置，保证 down/up 落在同一点
            "up(777,888)",
            "moved(10,20)"      // 收尾把指针送回原处
        ])
    }

    /// 把 CGEvent 压成 "类型(x,y)" 便于断言
    private static func describe(_ event: CGEvent) -> String {
        let name: String
        switch event.type {
        case .mouseMoved: name = "moved"
        case .leftMouseDown: name = "down"
        case .leftMouseUp: name = "up"
        default: name = "other"
        }
        let p = event.location
        return "\(name)(\(Int(p.x)),\(Int(p.y)))"
    }

    /// mouseUp 必须与 mouseDown 之间隔着 clickDwell 的阻塞停留。
    /// 零时长按下会被 Unity / UE 这类按帧轮询输入的目标整个漏掉
    /// （实测：PlayCover 上的崩坏：星穹铁道对 0ms 点击完全无响应，32ms 起正常）。
    func testDwellSeparatesMouseDownFromMouseUp() {
        var calls: [String] = []
        var sleptFor: TimeInterval?
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { CGPoint(x: 100, y: 100) },
            associate: { _ in },
            warp: { _ in },
            post: { calls.append(Self.describe($0)) }
        )
        ClickSimulator.shared.runClickSequence = { work in work() }
        ClickSimulator.shared.sleepForDwell = { sleptFor = $0; calls.append("sleep") }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 500, y: 500), targetApp: nil)

        let downIdx = calls.firstIndex(of: "down(500,500)")
        let sleepIdx = calls.firstIndex(of: "sleep")
        let upIdx = calls.firstIndex(of: "up(500,500)")
        XCTAssertNotNil(downIdx); XCTAssertNotNil(sleepIdx); XCTAssertNotNil(upIdx)
        XCTAssertTrue(downIdx! < sleepIdx! && sleepIdx! < upIdx!, "停留必须夹在 down 与 up 之间")
        XCTAssertEqual(sleptFor, ClickSimulator.clickDwell)
        XCTAssertGreaterThan(ClickSimulator.clickDwell, 1.0 / 60.0, "按压时长必须跨过至少一帧")
    }

    /// 整段序列必须交给 runClickSequence 一次性跑完，中途不得回到调用方。
    /// 这是核心不变量：实测把 mouseUp 拆到 main queue 的 asyncAfter 里（即光标
    /// disassociate 期间让出 run loop），PlayCover 就收不到成对的按下/抬起，点击全废。
    func testWholeSequenceRunsInsideOneScheduledBlock() {
        var calls: [String] = []
        var deferred: (() -> Void)?
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { CGPoint(x: 100, y: 100) },
            associate: { connected in calls.append("associate(\(connected ? "true" : "false"))") },
            warp: { _ in calls.append("warp") },
            post: { calls.append(Self.describe($0)) }
        )
        // 扣住不执行 → 若有任何一步发生在块外，就会提前出现在 calls 里
        ClickSimulator.shared.runClickSequence = { deferred = $0 }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 500, y: 500), targetApp: nil)
        XCTAssertTrue(calls.isEmpty, "块未执行前不应有任何光标操作或事件投递")

        deferred?()
        XCTAssertEqual(calls.first, "associate(false)")
        XCTAssertEqual(calls.last, "associate(true)", "冻结与恢复必须在同一个块内闭合")
    }

    /// 连击由串行队列天然保证不交错：每次点击都是一段自洽闭合的序列，
    /// associate(false)/associate(true) 成对且数量相等，光标不会被卡在解除关联状态。
    func testEachClickIsSelfContainedAndBalanced() {
        var calls: [String] = []
        var blocks: [() -> Void] = []
        ClickSimulator.shared.cursorOps = ClickSimulator.CursorOps(
            currentLocation: { CGPoint(x: 100, y: 100) },
            associate: { connected in calls.append("associate(\(connected ? "true" : "false"))") },
            warp: { _ in },
            post: { _ in }
        )
        ClickSimulator.shared.runClickSequence = { blocks.append($0) }
        ClickSimulator.shared.sleepForDwell = { _ in }
        defer { Self.restore() }

        ClickSimulator.shared.leftClick(at: CGPoint(x: 500, y: 500), targetApp: nil)
        ClickSimulator.shared.leftClick(at: CGPoint(x: 600, y: 600), targetApp: nil)
        blocks.forEach { $0() }   // 串行队列语义：一个跑完才跑下一个

        XCTAssertEqual(calls, [
            "associate(false)", "associate(true)",
            "associate(false)", "associate(true)"
        ], "两次点击各自闭合，不会交错")
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
