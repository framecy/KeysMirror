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
        statusBarController.update(
            permissionGranted: permissionChecker.isAccessibilityGranted,
            interceptorEnabled: keyInterceptor.isEnabled
        )
        
        if permissionChecker.isAccessibilityGranted {
            _ = keyInterceptor.start()
            statusBarController.update(permissionGranted: true, interceptorEnabled: keyInterceptor.isEnabled)
        }
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
