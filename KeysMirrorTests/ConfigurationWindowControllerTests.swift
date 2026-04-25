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

    /// 加固：正常 close（isReleasedWhenClosed=false）后 controller 必须保留 window 引用，
    /// 下次 show() 复用同一实例——否则每次开关都会泄漏一个 NSWindow + 丢失 SwiftUI 状态。
    func testWindowReferenceKeptAfterNormalClose() {
        ConfigurationWindowController.shared.show()
        XCTAssertTrue(ConfigurationWindowController.shared.hasWindowReference)
        guard let firstWindow = findConfigurationWindow() else {
            XCTFail("show() 后找不到配置窗口")
            return
        }

        firstWindow.close()
        XCTAssertTrue(ConfigurationWindowController.shared.hasWindowReference,
                      "isReleasedWhenClosed=false 模式下 close 只是隐藏，强引用必须保留")

        ConfigurationWindowController.shared.show()
        XCTAssertTrue(ConfigurationWindowController.shared.hasWindowReference)
        // 复用旧实例：第二次 show 不应触发 init 路径
        XCTAssertNotNil(firstWindow.contentView, "复用的 window contentView 应仍然有效")
    }

    /// 副防线：若主防线（isReleasedWhenClosed=false）被未来重构误删，
    /// willCloseNotification handler 必须在窗口被释放前 nil 掉强引用，杜绝野指针。
    /// 这里直接构造一个 isReleasedWhenClosed=true 的 NSWindow 并触发通知，验证 handler 行为。
    func testWillCloseHandlerNilsReferenceWhenWindowIsReleasable() {
        ConfigurationWindowController.shared.show()
        XCTAssertTrue(ConfigurationWindowController.shared.hasWindowReference)
        guard let win = findConfigurationWindow() else {
            XCTFail("show() 后找不到配置窗口")
            return
        }

        // 模拟「主防线被误删」：把 release 标志翻回 true，让 handler 进入 nil 分支
        win.isReleasedWhenClosed = true
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: win)

        XCTAssertFalse(ConfigurationWindowController.shared.hasWindowReference,
                       "isReleasedWhenClosed=true 时 willClose handler 必须 nil 强引用，下次 show() 才能重建")

        // 复位，避免污染后续测试
        win.isReleasedWhenClosed = false
        win.close()
    }

    private func findConfigurationWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == windowTitle }
    }
}
