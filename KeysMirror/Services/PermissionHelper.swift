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

    /// 通过 tccutil 重置 KeysMirror 的辅助功能授权记录（解决权限「卡死失效」场景）。
    ///
    /// 这是排障核弹：执行后所有映射与宏立刻停止工作，必须手动去系统设置重新勾选一次
    /// 才能恢复。菜单里一点就执行太危险，所以先二次确认；而且它**经常静默失败**
    /// （系统对 tccutil 的限制、SIP 状态、非 /Applications 运行位置都可能让它拒绝执行），
    /// 失败了必须说出来——不然用户会以为「重置过了还是不好使」，实际根本没重置成。
    static func resetAccessibility() {
        guard confirmReset() else {
            AppLogger.shared.log("用户取消了权限重置")
            return
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.keysmirror.KeysMirror"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", bundleID]
        let errorPipe = Pipe()
        task.standardError = errorPipe
        task.standardOutput = Pipe()

        do {
            try task.run()
            // 读管道要在 waitUntilExit 之前：tccutil 输出很少，不会撑爆管道缓冲，
            // 但顺序反了在输出变多时会死锁，这里按安全写法来。
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard task.terminationStatus == 0 else {
                let detail = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                reportResetFailure(detail.isEmpty ? "tccutil 返回错误码 \(task.terminationStatus)" : detail)
                return
            }
        } catch {
            reportResetFailure(error.localizedDescription)
            return
        }

        AppLogger.shared.log("权限记录已重置，请重新授权")
        PermissionChecker.shared.refreshStatus()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "权限记录已重置"
        alert.informativeText = "映射和宏现在处于停用状态。请到「系统设置 → 隐私与安全性 → 辅助功能」里重新勾选 KeysMirror。"
        alert.addButton(withTitle: "去设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            forceGrantAccessibility()
        }
    }

    private static func confirmReset() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "要重置辅助功能授权吗？"
        alert.informativeText = """
        这会清掉系统里记着的「已允许 KeysMirror 控制电脑」，映射和宏立刻停止工作。
        重置后你必须手动去「系统设置 → 隐私与安全性 → 辅助功能」重新勾选一次才能继续使用。

        只有在权限明明勾着、功能却完全没反应时才需要这一步。
        """
        alert.addButton(withTitle: "重置")
        alert.addButton(withTitle: "取消")
        // 默认落在「取消」上：回车不该触发一个需要用户善后的操作
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func reportResetFailure(_ detail: String) {
        AppLogger.shared.log("权限重置失败：\(detail)", type: "ERROR")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "没能重置权限记录"
        alert.informativeText = """
        系统拒绝了这次重置，你的授权状态没有任何改变（也就是说不用担心把什么弄坏了）。

        可以改成手动来：到「系统设置 → 隐私与安全性 → 辅助功能」里，把 KeysMirror 的开关关掉再打开；\
        如果列表里根本没有它，先用「-」移除再重新添加。

        技术细节：\(detail)
        """
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn {
            forceGrantAccessibility()
        }
    }
}
