import SwiftUI

/// 轻提示：替代成功类 `Alert`，可携带一个「撤销」动作。
struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var systemImage: String = "checkmark.circle.fill"
    var tint: Color = Theme.Palette.success
    /// 有值时右侧显示按钮；点击后 toast 立即消失
    var actionTitle: String?
    var action: (() -> Void)?

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

/// Toast 队列宿主。用 `.toast($model)` 挂在窗口根视图上。
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: ToastMessage?

    private var dismissTask: Task<Void, Never>?
    private init() {}

    func show(_ message: ToastMessage, duration: TimeInterval = 4) {
        dismissTask?.cancel()
        current = message
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    /// 便捷入口：成功 / 撤销
    func success(_ text: String) {
        show(ToastMessage(text: text))
    }

    func undoable(_ text: String, undo: @escaping () -> Void) {
        show(ToastMessage(text: text, systemImage: "trash", tint: Theme.Palette.danger, actionTitle: "撤销", action: undo))
    }

    func failure(_ text: String) {
        show(ToastMessage(text: text, systemImage: "exclamationmark.triangle.fill", tint: Theme.Palette.warning), duration: 6)
    }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

struct ToastView: View {
    let message: ToastMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: message.systemImage)
                .foregroundStyle(message.tint)
            Text(message.text)
                .font(Theme.Typography.body)
                .lineLimit(2)
            if let title = message.actionTitle, let action = message.action {
                Button(title) {
                    action()
                    onDismiss()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .floatingSurface()
    }
}

private struct ToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if let message = center.current {
                ToastView(message: message) { center.dismiss() }
                    .padding(Theme.Spacing.lg)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
            }
        }
        .animation(Theme.Motion.standard(reduceMotion), value: center.current)
    }
}

extension View {
    /// 挂载 Toast 层（每个窗口根视图挂一次）
    func toastHost() -> some View { modifier(ToastHost()) }
}
