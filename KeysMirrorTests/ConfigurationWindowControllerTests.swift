import XCTest
import AppKit
@testable import KeysMirror

/// 回归：v1.5.1 之前 ConfigurationWindowController 持有的 NSWindow 默认
/// `isReleasedWhenClosed = true`，用户点红叉关闭后底层对象被释放，
/// 下次 `show()` 调 `makeKeyAndOrderFront` 触发 objc_msgSend 野指针闪退。
@MainActor
final class ConfigurationWindowControllerTests: XCTestCase {
    private let windowTitle = "KeysMirror 配置"

    override func tearDown() async throws {
        // 每个用例结束时关掉窗口，避免互相污染
        ConfigurationWindowController.shared.hide()
    }

    /// 关键断言：window 必须 isReleasedWhenClosed = false，
    /// 否则关闭后底层释放，controller 持野指针。
    func testWindowIsNotReleasedWhenClosed() {
        ConfigurationWindowController.shared.show()
        guard let window = findConfigurationWindow() else {
            XCTFail("show() 后找不到配置窗口")
            return
        }
        XCTAssertFalse(
            window.isReleasedWhenClosed,
            "配置窗口必须 isReleasedWhenClosed=false，否则 close 后再 show 会 objc_msgSend 野指针"
        )
    }

    /// 回归崩溃路径：show → 关闭 → show 不得 crash。
    func testShowAfterCloseDoesNotCrash() {
        ConfigurationWindowController.shared.show()
        guard let first = findConfigurationWindow() else {
            XCTFail("首次 show() 后找不到配置窗口")
            return
        }
        // 模拟用户点红叉
        first.close()

        // 第二次 show —— 修复前此处走 makeKeyAndOrderFront 向已释放 NSWindow 发消息 → SIGSEGV
        ConfigurationWindowController.shared.show()
        XCTAssertNotNil(findConfigurationWindow(), "close 后再 show 应能找到配置窗口")
    }

    /// 连续多次 show/close 不得泄漏、不得 crash。覆盖长时间运行下用户反复开关的场景。
    func testRepeatedShowHideCycles() {
        for _ in 0..<5 {
            ConfigurationWindowController.shared.show()
            XCTAssertNotNil(findConfigurationWindow())
            ConfigurationWindowController.shared.hide()
        }
        // 再 close 一次（模拟红叉）然后 show，也应正常
        findConfigurationWindow()?.close()
        ConfigurationWindowController.shared.show()
        XCTAssertNotNil(findConfigurationWindow())
    }

    private func findConfigurationWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == windowTitle }
    }
}
