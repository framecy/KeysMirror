import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MappingStore.shared
    private let statusBarController = StatusBarController.shared
    private let permissionChecker = PermissionChecker.shared
    private let keyInterceptor = KeyInterceptor.shared
    private let overlayController = OverlayController.shared
    private let preferencesStore = PreferencesStore.shared
    private let globalHotkey = GlobalHotkeyManager.shared

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
        registerFrontAppObserver()
        // 启动 AX observer 必须在订阅者（WindowLocator/OverlayController）已设置回调后
        ActiveAppAXObserver.shared.bootstrap()
        // 初始化时按当前前台 app 决定是否启用 tap
        refreshActiveProfileAvailability()

        registerGlobalHotkey()
        auditLegacyMappings()
    }

    /// 启动时扫描所有 profile，对缺少缩放参考的旧映射给出明确警告。
    /// 无参考的映射在窗口缩放后点击位置不会跟随，可能落在窗口外唤醒后台 app。
    private func auditLegacyMappings() {
        var legacyCount = 0
        for profile in store.profiles {
            let legacy = profile.mappings.filter { !$0.hasScaleReference }
            for mapping in legacy {
                AppLogger.shared.log("旧映射缺缩放参考: [\(profile.appName)] \(mapping.label)（\(mapping.displayShortcut)）— 编辑此映射并「重录位置」即可启用窗口缩放跟随", type: "WARN")
                legacyCount += 1
            }
        }
        if legacyCount > 0 {
            AppLogger.shared.log("共 \(legacyCount) 条旧映射缺缩放参考，缩放跟随对其不生效", type: "WARN")
        }
    }

    // MARK: - 全局开关 hotkey

    private func registerGlobalHotkey() {
        globalHotkey.onTrigger = { [weak self] in
            self?.toggleInterceptor()
        }
        if let config = preferencesStore.preferences.globalToggleHotkey {
            _ = globalHotkey.register(config)
        }
    }

    /// 配置 UI 修改 hotkey 后调用，重新注册并写入 preferences
    func updateGlobalHotkey(_ config: HotkeyConfig?) {
        preferencesStore.update { $0.globalToggleHotkey = config }
        if let config {
            _ = globalHotkey.register(config)
        } else {
            globalHotkey.unregister()
        }
    }

    // MARK: - 前台应用切换：智能 tap 暂停

    private func registerFrontAppObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleFrontAppChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // profile 增删改也可能改变当前前台 app 的可用性
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStoreChange),
            name: .mappingStoreDidChange,
            object: nil
        )
    }

    @objc private func handleFrontAppChange(_ note: Notification) {
        refreshActiveProfileAvailability()
    }

    @objc private func handleStoreChange() {
        refreshActiveProfileAvailability()
    }

    private func refreshActiveProfileAvailability() {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let hasProfile: Bool
        if let bundleId, bundleId != Bundle.main.bundleIdentifier,
           let profile = store.enabledProfile(bundleIdentifier: bundleId) {
            // 至少有一条启用的 mapping 或 macro 才视为"有用"
            let hasEnabledMapping = profile.mappings.contains { $0.isEnabled }
            let hasEnabledMacro = profile.macros.contains { $0.isEnabled }
            hasProfile = hasEnabledMapping || hasEnabledMacro
        } else {
            hasProfile = false
        }
        keyInterceptor.setActiveProfileAvailable(hasProfile)
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
        // 唤醒后事件 tap 可能已被系统销毁，重建；运行中的宏 Task 也可能被休眠扰乱，统一停掉
        MacroRunner.shared.stop(reason: "系统唤醒")
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
