import Foundation
import AppKit

@MainActor
enum PermissionHelper {
    /// 打开系统"辅助功能"设置面板，引导用户手动勾选 KeysMirror。
    static func forceGrantAccessibility() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "KeysMirror"

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        AppLogger.shared.log("已尝试打开辅助功能设置页面，请手动勾选 \(appName)")
    }

    /// 通过 tccutil 重置 KeysMirror 的辅助功能授权记录（解决权限"卡死失效"场景）。
    static func resetAccessibility() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.keysmirror.KeysMirror"
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "Accessibility", bundleID]
        task.launch()
        task.waitUntilExit()

        AppLogger.shared.log("权限记录已重置，请重新授权")
        PermissionChecker.shared.refreshStatus()
    }
}
