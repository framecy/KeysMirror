import AppKit

struct RunningApplication: Identifiable, Hashable {
    let id: String
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage?
}

@MainActor
final class AppResolver {
    static let shared = AppResolver()

    private var iconCache: [String: NSImage] = [:]

    private init() {}

    func runningApplications() -> [RunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleIdentifier = app.bundleIdentifier else { return nil }
                return RunningApplication(
                    id: bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    displayName: app.localizedName ?? bundleIdentifier,
                    icon: app.icon
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// 取某个 bundle id 的应用图标，**不要求它正在运行**。
    ///
    /// 侧栏里已配置的应用即使没启动也该显示自己的图标（只是去饱和/变暗表示未运行）。
    /// 运行中直接用进程的 icon；没运行则通过 LaunchServices 反查 bundle 路径再取图标。
    /// 结果按 bundle id 缓存——读盘取图标不便宜，而侧栏每次刷新都会问一遍。
    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        if let cached = iconCache[bundleIdentifier] { return cached }

        let image: NSImage?
        if let running = runningApplication(bundleIdentifier: bundleIdentifier), let icon = running.icon {
            image = icon
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = nil
        }
        // 只缓存取到的结果：没装/没找到时留待下次重试（用户可能刚装上）
        if let image { iconCache[bundleIdentifier] = image }
        return image
    }

    /// 判断某个已知 bundle id 是否在运行——不按 `activationPolicy` 过滤。
    ///
    /// `runningApplications()` 过滤 `.regular` 是为了「选择正在运行的应用」这个添加流程排除
    /// 后台守护进程；但已配置好的 profile 不需要这层过滤——iOS-on-Mac 移植的游戏经常没有
    /// 标准菜单栏/Dock 存在感，`activationPolicy` 会是 `.accessory` 甚至 `.prohibited`，
    /// 用同一套过滤会导致游戏明明在运行，侧栏却一直显示「未运行」。
    func runningApplicationInfo(bundleIdentifier: String) -> RunningApplication? {
        guard let app = runningApplication(bundleIdentifier: bundleIdentifier) else { return nil }
        return RunningApplication(
            id: bundleIdentifier,
            bundleIdentifier: bundleIdentifier,
            displayName: app.localizedName ?? bundleIdentifier,
            icon: app.icon
        )
    }

    /// 把目标 app 切到前台。
    ///
    /// `activate(options:)` 在 macOS 14+ 已废弃，且在新系统上经常直接返回 false（录制时
    /// 表现为「点了录制但游戏没切过来」）。这里按系统版本走新 API，并且失败时用
    /// `NSWorkspace.openApplication` 兜底——对已在运行的 app，它等价于「点一下 Dock 图标」。
    @discardableResult
    func activate(bundleIdentifier: String) -> Bool {
        guard let application = runningApplication(bundleIdentifier: bundleIdentifier) else {
            return false
        }

        application.unhide()

        let activated: Bool
        if #available(macOS 14.0, *) {
            activated = application.activate(from: .current, options: [.activateAllWindows])
        } else {
            activated = application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        if activated { return true }

        guard let url = application.bundleURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }
}
