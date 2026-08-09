import SwiftUI

@MainActor
final class ConfigurationWindowController {
    static let shared = ConfigurationWindowController()

    private var window: NSWindow?
    private var willCloseObserver: NSObjectProtocol?

    /// 测试钩子：close 后 willClose 通知必须把强引用清干净。
    var hasWindowReference: Bool { window != nil }

    func show() {
        // 主防线：isReleasedWhenClosed = false 让 close 不释放底层对象。
        // 副防线：监听 willClose，发生时主动 nil 强引用——即使主防线被未来重构误删，
        // 下次 show() 看到 nil 直接重建，杜绝野指针 objc_msgSend 闪退。
        if window == nil {
            let rootView = MainWindow()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            // 标题保持短：工具栏项一多，长标题会被系统截断成「KeysMirror 配置 v1…」。
            // 版本放 subtitle（系统会在空间不足时自己隐藏），完整信息在「更多」菜单里。
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            window.title = "KeysMirror v\(version)"     // 仅用于窗口菜单 / 辅助功能
            window.titleVisibility = .hidden             // 标题与操作都在自绘头栏里
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.center()

            // NSHostingView 默认避开标题栏安全区，于是自绘头栏会**叠在**系统标题栏下面，
            // 白白多出一条空白。清掉 safeAreaRegions，让头栏自己占据标题栏那一行
            // （头栏左侧预留了 72pt 给红绿灯）。
            window.contentView = NSHostingView(rootView: rootView)

            // 副防线只在「窗口即将真的被释放」时触发：
            // 正常情况下 isReleasedWhenClosed=false，close 只是隐藏，引用保留以复用 SwiftUI 状态；
            // 若未来重构误把 isReleasedWhenClosed 改回 true（默认值），close 后底层会释放，
            // 这里在 dealloc 之前主动 nil 强引用，下次 show() 看到 nil 直接重建，不会野指针闪退。
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // observer 已绑定到特定 window（object: window），每次回调一定是这个窗口，
                // 不必从 note 解包——note: Notification 不 Sendable，跨 actor 传会被 strict
                // concurrency 拦下。直接通过 self.window 检查 isReleasedWhenClosed。
                assumingMainActor {
                    guard self?.window?.isReleasedWhenClosed == true else { return }
                    self?.releaseWindow()
                }
            }

            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func releaseWindow() {
        if let obs = willCloseObserver {
            NotificationCenter.default.removeObserver(obs)
            willCloseObserver = nil
        }
        window = nil
    }
}
