import SwiftUI

/// 三态状态点：启用（实心）/ 禁用（空心）/ 运行中（实心 + 呼吸）。
/// 状态不只靠颜色区分——形状本身可辨，满足无障碍要求。
struct StatusDot: View {
    enum State: Hashable {
        case enabled
        case disabled
        case running
    }

    let state: State
    var size: CGFloat = Theme.Metrics.statusDotSize

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var breathing = false

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.5)
            .background(Circle().fill(state == .disabled ? Color.clear : color))
            .frame(width: size, height: size)
            .opacity(state == .running && breathing && !reduceMotion ? 0.45 : 1)
            .animation(Theme.Motion.ambient(reduceMotion), value: breathing)
            .onAppear { breathing = state == .running }
            .onChange(of: state) { newValue in breathing = newValue == .running }
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .enabled: return Theme.Palette.success
        case .disabled: return .secondary
        case .running: return Theme.Palette.danger
        }
    }

    private var label: String {
        switch state {
        case .enabled: return "已启用"
        case .disabled: return "已禁用"
        case .running: return "运行中"
        }
    }
}

#Preview {
    HStack(spacing: Theme.Spacing.lg) {
        StatusDot(state: .enabled)
        StatusDot(state: .disabled)
        StatusDot(state: .running)
    }
    .padding()
}
