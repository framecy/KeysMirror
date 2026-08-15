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

    // MARK: - clickPlan（前台 / 后台分支）

    /// 目标已在前台时必须和 KeyInterceptor 走完全相同的投递参数。
    ///
    /// 这是 v1.7.0 那两个用户可复现问题的直接成因，必须锁死：
    /// ① 开了 suppressLocalInput → 宏步会吞掉玩家的物理鼠标，和按键映射叠用就是「鼠标闪 / 顿」；
    /// ② 点完还去 activate → 游戏本来就在前台，等于每步重抢一次焦点，
    ///    表现成「宏把游戏窗口又激活了一遍」。
    func testForegroundTargetUsesPlainClickPath() {
        let plan = MacroRunner.clickPlan(targetIsFront: true)
        XCTAssertFalse(plan.suppressLocalInput, "前台绝不能屏蔽物理鼠标——会和按键映射叠成鼠标闪")
        XCTAssertFalse(plan.tagTargetProcess)
        XCTAssertFalse(plan.restoresPreviousApp, "目标本来就在前台，还原=每步重抢焦点")
        XCTAssertEqual(plan, MacroRunner.ClickPlan(
            suppressLocalInput: false, tagTargetProcess: false, restoresPreviousApp: false,
            checksOcclusion: true
        ))
        XCTAssertTrue(plan.checksOcclusion,
                      "前台目标的窗口也可能被浮动窗口盖住一角，session 点击会打进那个窗口")
    }

    /// 目标在后台（用户显式选了「允许后台执行」）：三个开关全开。
    /// suppress 防止用户正在动鼠标时把这一击挤掉；tag 让收尾的 movedBack 不广播给
    /// 光标底下的别的 app；restore 负责把被抢走的前台还回去。
    func testBackgroundTargetUsesSuppressedAndRestoringPath() {
        XCTAssertEqual(MacroRunner.clickPlan(targetIsFront: false), MacroRunner.ClickPlan(
            suppressLocalInput: true, tagTargetProcess: true, restoresPreviousApp: true,
            checksOcclusion: true
        ))
    }

    /// 后台宏点第一下就会把目标顶到前台。第二步再看「目标在不在前台」，答案是「在」——
    /// 但那是宏自己顶上去的。若因此退回前台参数，三条保护会连锁失效：
    /// ① 不再刷新防抖还原 → 挂起中的那次照样在 150ms 后触发，紧接着又被下一步点击抢回去，
    ///    前台开始以 150ms 为周期在游戏和用户窗口之间横跳（正是防抖本来要消除的现象）；
    /// ② 不再打 tag → 收尾的 movedBack 广播给光标底下的 app；
    /// ③ 不再 suppress → 用户真实的鼠标移动能把这一击带偏。
    func testFrontStolenByMacroStillUsesBackgroundPath() {
        let plan = MacroRunner.clickPlan(targetIsFront: true, frontStolenByMacro: true)
        XCTAssertEqual(plan, MacroRunner.ClickPlan(
            suppressLocalInput: true, tagTargetProcess: true, restoresPreviousApp: true,
            checksOcclusion: true
        ), "前台是宏自己抢来的，不能当成用户切过去的")
    }

    /// 原生 macOS App 走 postToPid：完全绕开 Window Server，不动光标也不激活窗口。
    /// 三个开关都是给 session 投递擦屁股用的，这里一个都不能开——尤其 suppressLocalInput，
    /// 它每次点击都会冻结用户的物理鼠标约一个 dwell，后台跑无限循环宏就是持续抢指针。
    func testNativeTargetNeverSuppressesOrRestoresEvenInBackground() {
        let plan = MacroRunner.clickPlan(targetIsFront: false, targetIsNative: true)
        XCTAssertEqual(plan, MacroRunner.ClickPlan(
            suppressLocalInput: false, tagTargetProcess: false, restoresPreviousApp: false,
            checksOcclusion: false
        ), "postToPid 不碰光标也不碰前台，没有要防的东西")
        XCTAssertEqual(
            MacroRunner.clickPlan(targetIsFront: true, targetIsNative: true, frontStolenByMacro: true),
            plan,
            "原生路径压根不会抢前台，frontStolenByMacro 不该改变结论"
        )
    }

    /// 遮挡检查必须只对 session 投递生效。原生 App 走 postToPid，事件直接进目标进程，
    /// 上面盖着谁都收不到——查遮挡等于把后台宏全部误杀：用户在自己的窗口里干活，
    /// 那扇窗口天然盖在目标上面，每一步都会被判「被遮挡，已跳过」。
    func testOcclusionCheckOnlyAppliesToSessionDelivery() {
        XCTAssertFalse(MacroRunner.clickPlan(targetIsFront: false, targetIsNative: true).checksOcclusion,
                       "遮挡对 postToPid 不成立，查了只会误杀后台宏")
        XCTAssertTrue(MacroRunner.clickPlan(targetIsFront: false, targetIsNative: false).checksOcclusion,
                      "session 点击按光标下的窗口路由，不查就会打进别人的窗口")
    }

    // MARK: - 「仅前台执行」的约束范围

    /// 「仅前台执行」的代价只存在于 iOS-on-Mac：它们的点击走 session 层，会把后台窗口
    /// 顶到前台。原生 App 走 postToPid，后台点击零副作用，跳过它纯属白白牺牲功能。
    func testFrontmostOnlyDoesNotConstrainNativeApps() {
        XCTAssertFalse(MacroRunner.shouldSkipBecauseBackground(
            targetIsFront: false, targetIsNative: true, policy: .frontmostOnly
        ), "原生 App 后台点击不抢焦点、不动光标，没有理由跳过")
    }

    /// iOS-on-Mac 在「仅前台执行」下必须照旧跳过——这一档的承诺就是不打断用户。
    func testFrontmostOnlyStillSkipsBackgroundIOSApps() {
        XCTAssertTrue(MacroRunner.shouldSkipBecauseBackground(
            targetIsFront: false, targetIsNative: false, policy: .frontmostOnly
        ))
    }

    /// 遮挡安全网的实验开关默认必须是关的：打开后点击会真的打进用户自己的窗口。
    func testOcclusionOverrideIsOffByDefault() {
        XCTAssertFalse(MacroRunner.ignoreOcclusion,
                       "测试进程没设 KEYSMIRROR_IGNORE_OCCLUSION，必须是关的")
    }

    /// 目标在前台时两类应用都不跳过；选了「允许后台执行」时也都不跳过。
    func testNothingIsSkippedWhenTargetIsFrontOrPolicyAllowsBackground() {
        for native in [true, false] {
            XCTAssertFalse(MacroRunner.shouldSkipBecauseBackground(
                targetIsFront: true, targetIsNative: native, policy: .frontmostOnly
            ), "目标在前台，没有跳过的理由（native=\(native)）")
            XCTAssertFalse(MacroRunner.shouldSkipBecauseBackground(
                targetIsFront: false, targetIsNative: native, policy: .allowActivation
            ), "用户显式选了允许后台执行（native=\(native)）")
        }
    }

    /// 还原必须是防抖的，不能每步点完立刻抢回去——否则第 N 步的还原会和
    /// 第 N+1 步的点击迎面撞上，前台在游戏和用户窗口之间来回横跳。
    func testRestoreDebounceIsLongEnoughToCoalesceConsecutiveSteps() {
        XCTAssertGreaterThanOrEqual(MacroRunner.restoreDebounce, 0.1,
                                    "太短则连续宏步之间会反复抢焦点")
        XCTAssertLessThanOrEqual(MacroRunner.restoreDebounce, 0.5,
                                 "太长则用户会觉得点完半天才切回来")
    }

    // MARK: - 激活来源判定（宏顶上去的 vs 用户自己切过去的）

    /// 投递期间的激活是点击的副作用，必须认成宏干的——否则每点一下都会以为
    /// 「用户切过去了」，前台再也不还回来。
    func testActivationDuringDeliveryCountsAsMacroCaused() {
        let click = Date()
        XCTAssertTrue(MacroRunner.activationIsMacroCaused(
            activatedAt: click.addingTimeInterval(0.005), lastBackgroundClickAt: click
        ))
        // 不断在精确边界上：Date 加减是浮点，click+grace 再求差会得到 0.2000000000000002。
        XCTAssertTrue(MacroRunner.activationIsMacroCaused(
            activatedAt: click.addingTimeInterval(MacroRunner.macroActivationGrace - 0.001),
            lastBackgroundClickAt: click
        ), "宽限期内的激活都算宏干的")
    }

    /// 宽限期之外的激活只能是用户自己切过去的：此时必须放弃还原，
    /// 否则用户为了停宏切回游戏，150ms 后又被弹回原来的窗口。
    func testActivationLongAfterDeliveryCountsAsUserInitiated() {
        let click = Date()
        XCTAssertFalse(MacroRunner.activationIsMacroCaused(
            activatedAt: click.addingTimeInterval(MacroRunner.macroActivationGrace + 0.05),
            lastBackgroundClickAt: click
        ))
    }

    /// 压根没投递过后台点击 → 任何激活都是用户自己的操作。
    func testActivationWithoutAnyBackgroundClickIsUserInitiated() {
        XCTAssertFalse(MacroRunner.activationIsMacroCaused(
            activatedAt: Date(), lastBackgroundClickAt: nil
        ))
    }

    /// 宽限期要覆盖得住一次投递（含每应用可配的最长 dwell），又不能长到把用户的手动切换
    /// 也吞进去——否则用户切回目标想停宏，会被判成「宏干的」继续踢人。
    func testActivationGraceCoversOneDeliveryButNotAUserSwitch() {
        XCTAssertGreaterThanOrEqual(MacroRunner.macroActivationGrace,
                                    ClickSimulator.dwellRange.upperBound,
                                    "短于一次最长按压 → 投递自己引起的激活会被误判成用户操作")
        XCTAssertLessThanOrEqual(MacroRunner.macroActivationGrace, 0.5,
                                 "太长会把用户的手动切换也当成宏干的，继续把人踢出目标窗口")
    }
}
