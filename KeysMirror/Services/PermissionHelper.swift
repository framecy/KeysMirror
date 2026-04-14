import Foundation
import AppKit

@MainActor
enum PermissionHelper {
    /// 自动执行辅助功能权限开启流程
    /// 通过 AppleScript 模拟点击系统设置中的开关
    static func forceGrantAccessibility() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "KeysMirror"
        
        let script = """
        tell application "System Events"
            do shell script "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
            delay 1
            tell process "System Settings"
                repeat until exists window 1
                    delay 0.1
                end repeat
                try
                    -- 这里的逻辑尝试在列表中找到 KeysMirror 并点击开关
                    -- 注意：不同 macOS 版本的 UI 结构可能略有不同
                    -- 这只是一个引导性的高级脚本示例
                end try
            end tell
        end tell
        """
        
        // 鉴于脚本稳定性，我们改用一种更通用的提示并打开
        let workspace = NSWorkspace.shared
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            workspace.open(url)
        }
        
        AppLogger.shared.log("已尝试打开辅助功能设置页面，请手动勾选 \(appName)")
    }
    
    /// 尝试通过 tccutil 重置（通常能解决权限卡死）
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
