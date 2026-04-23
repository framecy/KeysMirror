import CoreGraphics
import Foundation
import AppKit

@MainActor
final class ClickSimulator {
    static let shared = ClickSimulator()

    // 按 bundleId 缓存 iOS-on-Mac 判定结果。首次判定需要读盘 (Info.plist)，
    // 后续同一 bundleId 的点击零 I/O。App 退出时对应项失效，避免升级/重装后过期。
    private var nativeCache: [String: Bool] = [:]

    // 测试接缝：注入 Info.plist 读取与 App 枚举逻辑
    var infoPlistProvider: (URL) -> NSDictionary? = { NSDictionary(contentsOf: $0) }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let bid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            // NSWorkspace notification 已在 main queue，直接 MainActor hop 修改缓存
            Task { @MainActor in
                self?.nativeCache.removeValue(forKey: bid)
            }
        }
    }

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

    // MARK: - Internal (testable)

    /// 判断是否为原生 macOS App（非 iOS-on-Mac）
    /// iOS App 的 Info.plist 中会包含 LSRequiresIPhoneOS = true
    func isNativeMacApp(_ app: NSRunningApplication) -> Bool {
        if let bid = app.bundleIdentifier, let cached = nativeCache[bid] {
            return cached
        }
        let result = computeIsNativeMacApp(app)
        if let bid = app.bundleIdentifier {
            nativeCache[bid] = result
        }
        return result
    }

    /// 测试用：手动清空缓存
    func clearNativeCacheForTesting() {
        nativeCache.removeAll()
    }

    private func computeIsNativeMacApp(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else {
            return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
        }
        let plistURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let plist = infoPlistProvider(plistURL) else {
            return !(app.bundleIdentifier?.hasSuffix(".ios") ?? false)
        }
        if let requiresIPhoneOS = plist["LSRequiresIPhoneOS"] as? Bool {
            return !requiresIPhoneOS
        }
        return true
    }
}
