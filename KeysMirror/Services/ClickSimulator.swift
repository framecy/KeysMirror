import CoreGraphics
import Foundation
import AppKit

@MainActor
final class ClickSimulator {
    static let shared = ClickSimulator()

    private init() {}

    func leftClick(at point: CGPoint, targetApp: NSRunningApplication? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0

        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up   = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
        else { return }

        let pid = targetApp?.processIdentifier ?? 0
        let isNative = targetApp.map { isNativeMacApp($0) } ?? true

        if pid > 0 && isNative {
            // 方案 A：postToPid — 原生 macOS App
            // 完全绕过 Window Server，光标本身不会移动，无需任何光标管理
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            // 方案 B：Session 层投递 — iOS-on-Mac App
            // Window Server 会依据 mouseCursorPosition 更新光标，需要冻结+还原
            let savedPos = CGEvent(source: nil)?.location ?? .zero
            CGAssociateMouseAndMouseCursorPosition(0)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            CGAssociateMouseAndMouseCursorPosition(1)
            CGWarpMouseCursorPosition(savedPos)
        }
    }

    // MARK: - Private

    /// 判断是否为原生 macOS App（非 iOS-on-Mac）
    /// iOS App 的 Info.plist 中会包含 LSRequiresIPhoneOS = true
    private func isNativeMacApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else {
            // 读不到 bundle，按 bundle ID 末尾做粗略判断
            return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
        }
        let plistURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: plistURL) else {
            return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
        }
        if let requiresIPhoneOS = plist["LSRequiresIPhoneOS"] as? Bool {
            return !requiresIPhoneOS
        }
        return true
    }
}