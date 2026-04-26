import CoreGraphics
import Foundation
import AppKit

@MainActor
final class ClickSimulator {
    static let shared = ClickSimulator()

    // 按 bundleId 缓存 iOS-on-Mac 判定结果。首次判定需要读盘 (Info.plist)，
    // 后续同一 bundleId 的点击零 I/O。App 退出时对应项失效，避免升级/重装后过期。
    private var nativeCache: [String: Bool] = [:]

    // CGEventSource 在整个生命周期内复用，省去每次点击的对象构造开销，
    // 同时 localEventsSuppressionInterval=0 只设一次，行为更稳定。
    private lazy var eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    // 测试接缝：注入 Info.plist 读取与 App 枚举逻辑
    var infoPlistProvider: (URL) -> NSDictionary? = { NSDictionary(contentsOf: $0) }

    // 测试接缝：注入 cursor 操控与 post 调用，纯逻辑测试不真的动光标。
    var cursorOps: CursorOps = .system

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
        guard
            let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up   = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
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
            // Window Server 会依据 mouseCursorPosition 更新光标，需要冻结+还原。
            // 顺序很关键：必须先 warp 回原位再 re-associate，否则会有一帧光标停在
            // click 点导致视觉抖动，连击时累积成「光标渐渐漂向 click 点」的怪象。
            let savedPos = cursorOps.currentLocation()
            cursorOps.associate(false)
            cursorOps.post(down)
            cursorOps.post(up)
            cursorOps.warp(savedPos)
            cursorOps.associate(true)
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

    /// 测试可注入的光标 / Session post 操作集合。production 用 `.system` 走真正的 CG 调用，
    /// 测试可换成记录式实现验证调用顺序。@unchecked Sendable：CG 函数本身线程安全，
    /// 测试用闭包仅 main thread 访问。
    struct CursorOps: @unchecked Sendable {
        var currentLocation: () -> CGPoint
        var associate: (Bool) -> Void
        var warp: (CGPoint) -> Void
        var post: (CGEvent) -> Void

        static let system = CursorOps(
            currentLocation: { CGEvent(source: nil)?.location ?? .zero },
            associate: { connected in CGAssociateMouseAndMouseCursorPosition(connected ? 1 : 0) },
            warp: { CGWarpMouseCursorPosition($0) },
            post: { $0.post(tap: .cgSessionEventTap) }
        )
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
