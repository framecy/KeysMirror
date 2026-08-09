import ApplicationServices
import AppKit

@MainActor
final class PermissionChecker: ObservableObject {
    static let shared = PermissionChecker()

    @Published private(set) var isAccessibilityGranted = false
    private var pollingTimer: Timer?

    /// 轮询期间检测到权限刚被授予时回调一次（随后停止轮询）。
    ///
    /// 原先这里直接 `KeyInterceptor.shared.start()` + `StatusBarController.shared.update(...)`——
    /// 一个「查权限」的服务顺手决定了拦截器起停和菜单栏长相，而且那段逻辑和 AppDelegate 里
    /// 启动 / 唤醒 / 手动 toggle 三处是重复的。改成把「权限到手了」这件事报上去，
    /// 由 AppDelegate 统一决定后续动作。
    var onAccessibilityGranted: (() -> Void)?

    private init() {}

    func refreshStatus() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        startPolling()
    }

    func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.refreshStatus()
                if self.isAccessibilityGranted {
                    self.pollingTimer?.invalidate()
                    self.pollingTimer = nil
                    self.onAccessibilityGranted?()
                }
            }
        }
    }
}
