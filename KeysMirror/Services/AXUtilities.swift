import ApplicationServices

/// AX 调用集中点。
///
/// 统一两件事：
///   1. 给所有 AXUIElement 设 500ms messaging timeout（系统默认是 6 秒，
///      目标 app 卡死时会把主线程拖住 6s 让 KeysMirror 假死）。
///   2. 区分「真正的错」和「app 不支持某种 AX 通知 / 属性」的预期失败码，
///      让上层日志降噪不需要自己记一份硬编码 code 表。
enum AXUtilities {
    /// AX 默认超时是 6s。这里用 500ms 上限——足够正常 app 应答（典型 1-5ms），
    /// 又能在 app 卡死时让我们快速 bail，不拖死主线程。
    static let messagingTimeoutSeconds: Float = 0.5

    /// 创建一个绑定到 pid 的 AX app element，并设好超时。
    static func makeAppElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        return element
    }

    /// 创建系统范围的 AX element（用于 hit-test），并设好超时。
    static func makeSystemWideElement() -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        return element
    }

    /// 这两个 code 在 AXObserverAddNotification / AXUIElementCopyAttributeValue
    /// 场景下属预期失败：很多 app 不暴露这些通知 / 属性，不算 bug。
    /// 上层日志据此降级。
    static let expectedNonSupportCodes: Set<Int> = [
        Int(AXError.cannotComplete.rawValue),       // -25204
        Int(AXError.attributeUnsupported.rawValue), // -25211
    ]

    static func isExpectedNonSupport(_ code: AXError) -> Bool {
        expectedNonSupportCodes.contains(Int(code.rawValue))
    }
}
