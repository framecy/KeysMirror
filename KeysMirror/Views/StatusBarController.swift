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
    private var flashWorkItem: DispatchWorkItem?

    private init() {}

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
        toggleMenuItem?.title = interceptorEnabled ? "禁用映射" : "启用映射"

        if let button = statusItem.button {
            let symbolName: String
            if !permissionGranted {
                symbolName = "keyboard.badge.ellipsis"
            } else if interceptorEnabled {
                symbolName = "keyboard.badge.eye"
            } else {
                symbolName = "keyboard"
            }
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "KeysMirror")
            button.image?.isTemplate = true
        }
    }

    func flashActivity() {
        guard let button = statusItem.button else { return }
        flashWorkItem?.cancel()
        button.contentTintColor = .systemGreen

        let workItem = DispatchWorkItem { [weak button] in
            button?.contentTintColor = nil
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
