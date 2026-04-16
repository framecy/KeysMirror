import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MappingStore.shared
    private let statusBarController = StatusBarController.shared
    private let permissionChecker = PermissionChecker.shared
    private let keyInterceptor = KeyInterceptor.shared
    private let overlayController = OverlayController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController.configure(
            onOpenConfiguration: { [weak self] in
                self?.showConfigurationWindow()
            },
            onToggleEnabled: { [weak self] in
                self?.toggleInterceptor()
            },
            onOpenAccessibilitySettings: { [weak self] in
                self?.permissionChecker.openAccessibilitySettings()
            },
            onQuit: { [weak self] in
                self?.quit()
            }
        )

        permissionChecker.refreshStatus()
        let axGranted = permissionChecker.isAccessibilityGranted
        AppLogger.shared.log("App 启动 | 辅助功能权限: \(axGranted ? "已授权" : "未授权")")

        statusBarController.update(
            permissionGranted: axGranted,
            interceptorEnabled: keyInterceptor.isEnabled
        )

        if axGranted {
            let started = keyInterceptor.start()
            AppLogger.shared.log("拦截器启动结果: \(started ? "成功" : "失败")")
            statusBarController.update(permissionGranted: true, interceptorEnabled: keyInterceptor.isEnabled)
        }

        registerSleepWakeObservers()
    }

    // MARK: - 睡眠/唤醒处理

    private func registerSleepWakeObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        // 屏幕唤醒（熄屏后亮屏）
        workspace.addObserver(self, selector: #selector(handleScreenWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        // 系统从睡眠恢复（合盖重开等）
        workspace.addObserver(self, selector: #selector(handleScreenWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func handleScreenWake() {
        guard permissionChecker.isAccessibilityGranted else { return }
        // 唤醒后事件 tap 可能已被系统销毁，重建
        _ = keyInterceptor.start()
        statusBarController.update(permissionGranted: true, interceptorEnabled: keyInterceptor.isEnabled)
    }

    private func showConfigurationWindow() {
        ConfigurationWindowController.shared.show()
    }

    func toggleInterceptor() {
        guard permissionChecker.isAccessibilityGranted else {
            permissionChecker.requestAccessibilityPermission()
            statusBarController.update(permissionGranted: false, interceptorEnabled: false)
            return
        }

        if keyInterceptor.isEnabled {
            keyInterceptor.stop()
        } else {
            _ = keyInterceptor.start()
        }
        statusBarController.update(permissionGranted: permissionChecker.isAccessibilityGranted, interceptorEnabled: keyInterceptor.isEnabled)
    }

    private func quit() {
        keyInterceptor.stop()
        NSApp.terminate(nil)
    }
}
