import ApplicationServices
import AppKit

extension Notification.Name {
    /// 焦点窗口的位置 / 尺寸变化，或焦点窗口本身切换。userInfo: ["pid": pid_t]
    /// 多订阅广播：WindowLocator 用它失效 frame 缓存；OverlayController 用它刷新位置；MacroRunner 用它失效 run-scoped 缓存。
    static let focusedWindowFrameChanged = Notification.Name("KeysMirror.focusedWindowFrameChanged")
}

/// 跟踪前台应用的 AXObserver。集中管理对前台 app 元素的焦点、窗口移动 / 缩放通知，
/// 替代 v1.3 之前对 AX IPC 的轮询 / 节流近似手段。
///
/// `onFocusedElementChanged` 单订阅闭包（仅 WindowLocator 用）；窗口 frame 变化走
/// `Notification.Name.focusedWindowFrameChanged` 广播，支持任意多订阅者。
@MainActor
final class ActiveAppAXObserver {
    static let shared = ActiveAppAXObserver()

    private(set) var currentPID: pid_t?
    private var observer: AXObserver?
    private var appElement: AXUIElement?

    /// 焦点 UI 元素变化（焦点在 textfield / 按钮 / WebArea 之间切换）
    var onFocusedElementChanged: ((pid_t) -> Void)?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    /// 启动时由 AppDelegate 调用一次，确保订阅者初始化后立即对接当前前台 app。
    func bootstrap() {
        if let app = NSWorkspace.shared.frontmostApplication {
            switchTo(pid: app.processIdentifier)
        }
    }

    @objc private func handleAppActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        switchTo(pid: app.processIdentifier)
        // 应用切换：焦点元素与窗口必然变化，主动触发一次回调让订阅者刷新
        onFocusedElementChanged?(app.processIdentifier)
        broadcastWindowFrameChanged(pid: app.processIdentifier)
    }

    private func broadcastWindowFrameChanged(pid: pid_t) {
        NotificationCenter.default.post(
            name: .focusedWindowFrameChanged,
            object: self,
            userInfo: ["pid": pid]
        )
    }

    private func switchTo(pid: pid_t) {
        guard pid != currentPID else { return }
        teardown()

        let element = AXUIElementCreateApplication(pid)
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, Self.callback, &newObserver)
        guard result == .success, let newObserver else {
            AppLogger.shared.log("AXObserverCreate 失败 (pid=\(pid), code=\(result.rawValue))", type: "WARN")
            return
        }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [String] = [
            kAXFocusedUIElementChangedNotification as String,
            kAXFocusedWindowChangedNotification as String,
            kAXWindowMovedNotification as String,
            kAXWindowResizedNotification as String,
        ]
        for name in notifications {
            let addResult = AXObserverAddNotification(newObserver, element, name as CFString, userData)
            if addResult != .success && addResult != .notificationAlreadyRegistered {
                AppLogger.shared.log("AXObserverAddNotification 失败 [\(name)] pid=\(pid) code=\(addResult.rawValue)", type: "WARN")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(newObserver),
            .commonModes
        )

        observer = newObserver
        appElement = element
        currentPID = pid
    }

    private func teardown() {
        if let observer {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        observer = nil
        appElement = nil
        currentPID = nil
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let me = Unmanaged<ActiveAppAXObserver>.fromOpaque(refcon).takeUnretainedValue()
        let notif = notification as String
        MainActor.assumeIsolated {
            guard let pid = me.currentPID else { return }
            // kAX*Notification 在 Swift 已桥接为 String，无需再 `as String`
            switch notif {
            case kAXFocusedUIElementChangedNotification:
                me.onFocusedElementChanged?(pid)
            case kAXFocusedWindowChangedNotification:
                me.onFocusedElementChanged?(pid)
                me.broadcastWindowFrameChanged(pid: pid)
            case kAXWindowMovedNotification,
                 kAXWindowResizedNotification:
                me.broadcastWindowFrameChanged(pid: pid)
            default:
                break
            }
        }
    }
}
