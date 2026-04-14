import ApplicationServices
import AppKit

@MainActor
final class PermissionChecker: ObservableObject {
    static let shared = PermissionChecker()

    @Published private(set) var isAccessibilityGranted = false
    private var pollingTimer: Timer?

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
                    _ = KeyInterceptor.shared.start()
                    StatusBarController.shared.update(
                        permissionGranted: self.isAccessibilityGranted,
                        interceptorEnabled: KeyInterceptor.shared.isEnabled
                    )
                }
            }
        }
    }
}
