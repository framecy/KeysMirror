import AppKit

@MainActor
final class StatusBarController {
    static let shared = StatusBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var openConfigurationHandler: (() -> Void)?
    private var toggleEnabledHandler: (() -> Void)?
    private var openAccessibilitySettingsHandler: (() -> Void)?
    private var quitHandler: (() -> Void)?

    private weak var toggleMenuItem: NSMenuItem?
    private weak var stopMacroMenuItem: NSMenuItem?
    private var flashWorkItem: DispatchWorkItem?

    /// 由 MacroRunner 通知驱动的宏运行状态。运行时菜单栏图标变红、菜单暴露停止项。
    private var macroRunning: Bool = false
    private var lastPermissionGranted: Bool = false
    private var lastInterceptorEnabled: Bool = false

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMacroRunStateChange),
            name: .macroRunStateDidChange,
            object: nil
        )
    }

    func configure(
        onOpenConfiguration: @escaping () -> Void,
        onToggleEnabled: @escaping () -> Void,
        onOpenAccessibilitySettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        openConfigurationHandler = onOpenConfiguration
        toggleEnabledHandler = onToggleEnabled
        openAccessibilitySettingsHandler = onOpenAccessibilitySettings
        quitHandler = onQuit

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard.badge.eye", accessibilityDescription: "KeysMirror")
            button.image?.isTemplate = true
        }

        menu.removeAllItems()
        let titleItem = NSMenuItem(title: "KeysMirror", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "禁用映射", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        toggleMenuItem = toggleItem

        let stopMacroItem = NSMenuItem(title: "停止运行的宏", action: #selector(stopMacro), keyEquivalent: "")
        stopMacroItem.target = self
        stopMacroItem.isHidden = true
        menu.addItem(stopMacroItem)
        stopMacroMenuItem = stopMacroItem

        let configurationItem = NSMenuItem(title: "打开配置", action: #selector(openConfiguration), keyEquivalent: "")
        configurationItem.target = self
        menu.addItem(configurationItem)

        let permissionMenu = NSMenuItem(title: "权限管理", action: nil, keyEquivalent: "")
        let subMenu = NSMenu()
        
        let openSettingsItem = NSMenuItem(title: "打开系统隐私设置...", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        openSettingsItem.target = self
        subMenu.addItem(openSettingsItem)
        
        subMenu.addItem(.separator())
        
        let sudoGrantItem = NSMenuItem(title: "使用密码授权 (修复失效)", action: #selector(sudoGrant), keyEquivalent: "")
        sudoGrantItem.target = self
        subMenu.addItem(sudoGrantItem)
        
        let resetItem = NSMenuItem(title: "重置权限记录", action: #selector(resetPermission), keyEquivalent: "")
        resetItem.target = self
        subMenu.addItem(resetItem)
        
        permissionMenu.submenu = subMenu
        menu.addItem(permissionMenu)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func update(permissionGranted: Bool, interceptorEnabled: Bool) {
        lastPermissionGranted = permissionGranted
        lastInterceptorEnabled = interceptorEnabled
        refreshAppearance()
    }

    private func refreshAppearance() {
        toggleMenuItem?.title = lastInterceptorEnabled ? "禁用映射" : "启用映射"

        if let button = statusItem.button {
            let symbolName: String
            if macroRunning {
                symbolName = "record.circle.fill"
            } else if !lastPermissionGranted {
                symbolName = "keyboard.badge.ellipsis"
            } else if lastInterceptorEnabled {
                symbolName = "keyboard.badge.eye"
            } else {
                symbolName = "keyboard"
            }
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "KeysMirror")
            // 运行宏时用红色显眼提示；其他时候模板色随系统
            if macroRunning {
                button.image?.isTemplate = false
                button.contentTintColor = .systemRed
            } else {
                button.image?.isTemplate = true
                button.contentTintColor = nil
            }
        }
    }

    @objc private func handleMacroRunStateChange() {
        let runner = MacroRunner.shared
        macroRunning = runner.runningMacroId != nil
        if macroRunning, let label = runner.runningMacroLabel {
            stopMacroMenuItem?.title = "停止运行的宏（\(label)）"
            stopMacroMenuItem?.isHidden = false
        } else {
            stopMacroMenuItem?.title = "停止运行的宏"
            stopMacroMenuItem?.isHidden = true
        }
        refreshAppearance()
    }

    @objc private func stopMacro() {
        MacroRunner.shared.stop(reason: "菜单栏手动停止")
    }

    func flashActivity() {
        // 宏运行时图标已是红色，跳过绿色 flash 避免来回闪烁
        if macroRunning { return }
        guard let button = statusItem.button else { return }
        flashWorkItem?.cancel()
        button.contentTintColor = .systemGreen

        let workItem = DispatchWorkItem { [weak self, weak button] in
            guard let self else { return }
            // 还原时如果宏正在运行，要恢复红色而非清空
            if self.macroRunning {
                button?.contentTintColor = .systemRed
            } else {
                button?.contentTintColor = nil
            }
        }
        flashWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    @objc private func toggleEnabled() {
        toggleEnabledHandler?()
    }

    @objc private func openConfiguration() {
        openConfigurationHandler?()
    }

    @objc private func openAccessibilitySettings() {
        openAccessibilitySettingsHandler?()
    }

    @objc private func sudoGrant() {
        PermissionHelper.forceGrantAccessibility()
    }

    @objc private func resetPermission() {
        PermissionHelper.resetAccessibility()
    }

    @objc private func quit() {
        quitHandler?()
    }
}
