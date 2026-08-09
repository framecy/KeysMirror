import AppKit
import SwiftUI

@MainActor
final class StatusBarController {
    static let shared = StatusBarController()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var openConfigurationHandler: (() -> Void)?
    private var toggleEnabledHandler: (() -> Void)?
    private var openAccessibilitySettingsHandler: (() -> Void)?
    private var quitHandler: (() -> Void)?

    /// 左键弹出的 SwiftUI 面板；右键仍走下面的 NSMenu（键盘导航 / 无障碍的降级路径）
    private let popover = NSPopover()

    private weak var toggleMenuItem: NSMenuItem?
    private weak var stopMacroMenuItem: NSMenuItem?
    private var flashWorkItem: DispatchWorkItem?
    private weak var marqueeView: MacroMarqueeView?

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
        // 输入活动闪烁：由 KeyInterceptor / MacroRunner 发通知，Services 层不再反向持有本控制器
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInputActivity),
            name: .inputActivityDidFire,
            object: nil
        )
    }

    @objc private func handleInputActivity() {
        flashActivity()
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
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // 跑马灯作为按钮的子视图，铺满按钮；它的 hitTest 返回 nil，
            // 点击照常由 button 处理，这里只负责画字。
            let marquee = MacroMarqueeView(frame: button.bounds)
            marquee.autoresizingMask = [.width, .height]
            marquee.isHidden = true
            button.addSubview(marquee)
            marqueeView = marquee
        }

        popover.behavior = .transient
        popover.animates = true

        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let titleItem = NSMenuItem(title: "KeysMirror v\(version)", action: nil, keyEquivalent: "")
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
    }

    /// 左键 → SwiftUI 面板；右键 → 传统菜单
    @objc private func handleStatusItemClick() {
        guard let button = statusItem.button else { return }
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp

        if isRightClick {
            statusItem.menu = menu
            button.performClick(nil)
            statusItem.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(nil)
            return
        }

        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanel(
                store: MappingStore.shared,
                macroRunner: MacroRunner.shared,
                preferences: PreferencesStore.shared,
                permissionChecker: PermissionChecker.shared,
                interceptorEnabled: lastInterceptorEnabled,
                frontBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                onToggleInterceptor: { [weak self] in
                    self?.toggleEnabledHandler?()
                },
                onOpenConfiguration: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openConfigurationHandler?()
                },
                onOpenDiagnostics: { [weak self] in
                    self?.popover.performClose(nil)
                    DiagnosticsWindowController.shared.show()
                },
                onOpenPermissions: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.openAccessibilitySettingsHandler?()
                },
                onQuit: { [weak self] in
                    self?.quitHandler?()
                }
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func update(permissionGranted: Bool, interceptorEnabled: Bool) {
        lastPermissionGranted = permissionGranted
        lastInterceptorEnabled = interceptorEnabled
        refreshAppearance()
    }

    private func refreshAppearance() {
        toggleMenuItem?.title = lastInterceptorEnabled ? "禁用映射" : "启用映射"

        // 图标状态规范（与面板、状态条一致）：
        //   宏运行中 → 单色播放图标（菜单栏惯例是单色模板图；彩色实心圆在这里太跳，
        //              而且旁边滚动的宏名称+次数本身就已经说明在运行了）
        //   无权限   → 描边 + 感叹号（橙）
        //   已启用   → **实心**（模板色随系统，看起来是"亮"的）
        //   已禁用   → **描边 + 灰**（一眼看出是关着的）
        if let button = statusItem.button {
            let symbolName: String
            if macroRunning {
                symbolName = "play.fill"
            } else if !lastPermissionGranted {
                symbolName = "exclamationmark.triangle"
            } else if lastInterceptorEnabled {
                symbolName = "keyboard.fill"
            } else {
                symbolName = "keyboard"
            }
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "KeysMirror")
            button.appearsDisabled = false

            let tint: NSColor?
            if macroRunning {
                image?.isTemplate = true
                tint = nil                             // 单色，跟随菜单栏前景色
            } else if !lastPermissionGranted {
                image?.isTemplate = false
                tint = .systemOrange
            } else if lastInterceptorEnabled {
                image?.isTemplate = true
                tint = nil                             // 模板色 = 系统前景色（实心、醒目）
            } else {
                image?.isTemplate = false
                tint = .secondaryLabelColor            // 灰色描边 = 未启用
            }
            applyIcon(image, tint: tint, to: button)
            button.toolTip = Self.statusTooltip(
                macroRunning: macroRunning,
                permissionGranted: lastPermissionGranted,
                interceptorEnabled: lastInterceptorEnabled
            )
        }
    }

    /// 纯函数，便于单测：菜单栏图标的 tooltip 文案
    static func statusTooltip(macroRunning: Bool, permissionGranted: Bool, interceptorEnabled: Bool) -> String {
        if macroRunning { return "KeysMirror · 宏运行中" }
        if !permissionGranted { return "KeysMirror · 缺少辅助功能权限" }
        return interceptorEnabled ? "KeysMirror · 映射启用中" : "KeysMirror · 映射已禁用"
    }

    @objc private func handleMacroRunStateChange() {
        let running = MacroRunner.shared.running
        macroRunning = !running.isEmpty

        if macroRunning {
            stopMacroMenuItem?.title = running.count == 1
                ? "停止运行的宏（\(running[0].label)）"
                : "停止全部宏（\(running.count) 条）"
            stopMacroMenuItem?.isHidden = false
        } else {
            stopMacroMenuItem?.title = "停止运行的宏"
            stopMacroMenuItem?.isHidden = true
        }

        updateMarquee(running)
        refreshAppearance()
    }

    /// 图标该画在哪：宏运行时交给跑马灯视图（它会靠左画），否则用按钮自带的 image。
    ///
    /// 不能两者都用——`NSStatusBarButton` 会把 `button.image` 在整个按钮里居中，
    /// 状态项撑到固定宽度后图标就压在滚动文字正中间了。
    private func applyIcon(_ image: NSImage?, tint: NSColor?, to button: NSStatusBarButton) {
        if macroRunning, let marquee = marqueeView {
            button.image = nil
            button.contentTintColor = nil
            marquee.icon = image
            marquee.iconTint = tint
        } else {
            button.image = image
            button.contentTintColor = tint
            marqueeView?.icon = nil
        }
    }

    /// 有宏在跑时把状态项撑到固定宽度，腾出位置横向滚动展示「名称 + 次数」；
    /// 全部停止后收回 variableLength，菜单栏恢复成只有图标。
    private func updateMarquee(_ running: [RunningMacro]) {
        guard let button = statusItem.button, let marquee = marqueeView else { return }

        guard !running.isEmpty else {
            marquee.text = ""
            marquee.isHidden = true
            statusItem.length = NSStatusItem.variableLength
            return
        }

        // 按内容收窄：固定宽度时短名称右边会空一大片，看起来像没居中
        let text = MacroMarqueeView.compose(running)
        let width = MacroMarqueeView.preferredWidth(for: text)
        statusItem.length = width

        // 不读 button.bounds：刚改完 statusItem.length，按钮还没重新布局，
        // 读到的是旧宽度（甚至高度为 0），文字区会算错——表现为不滚动 + 上下被裁。
        // 宽度我们自己知道，高度用状态栏标准厚度。
        marquee.frame = NSRect(x: 0, y: 0, width: width, height: NSStatusBar.system.thickness)
        marquee.isHidden = false
        marquee.text = text
    }

    @objc private func stopMacro() {
        MacroRunner.shared.stopAll(reason: "菜单栏手动停止")
    }

    /// 取消任何挂起的 flash 还原 work item，并立即恢复图标颜色。
    /// 退出前调用避免残留 dispatch 引用 self。
    func cancelFlash() {
        flashWorkItem?.cancel()
        flashWorkItem = nil
        // 宏运行时图标归跑马灯视图管，颜色由 refreshAppearance 维护，这里只需还原按钮自身
        statusItem.button?.contentTintColor = nil
    }

    private func flashActivity() {
        // 宏运行时图标已是红色，跳过绿色 flash 避免来回闪烁
        if macroRunning { return }
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
