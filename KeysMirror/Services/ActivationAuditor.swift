import AppKit

/// 前台切换取证。
///
/// 排查「宏运行时游戏被顶到前台」用：把每一次前台变化都记进日志，
/// 再和宏点击的时间戳对照，就能判定激活到底是不是点击引起的——
/// 而不是靠推断。日志里 `【前台】` 行与 `【点击·投递】` 行的毫秒差是关键证据：
///
/// - 激活紧跟在 down 之后（几毫秒内） → 确实是点击触发了窗口激活
/// - 激活发生在点击窗口之外            → 另有原因，得换方向查
///
/// 只在有宏运行时记录，平时不产生噪音。
@MainActor
final class ActivationAuditor {
    static let shared = ActivationAuditor()

    private var observer: NSObjectProtocol?
    private let logger = AppLogger.shared

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            assumingMainActor {
                let runner = MacroRunner.shared
                guard runner.isAnyRunning else { return }
                let name = app?.localizedName ?? "?"
                let bundle = app?.bundleIdentifier ?? "?"
                let isMacroTarget = runner.running.contains {
                    $0.bundleId.lowercased() == (app?.bundleIdentifier?.lowercased() ?? "")
                }
                AppLogger.shared.log(
                    "【前台】切到 \(name) (\(bundle))\(isMacroTarget ? " ← 是当前宏的目标应用" : "")",
                    type: isMacroTarget ? "WARN" : "ACTION"
                )
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }
}
