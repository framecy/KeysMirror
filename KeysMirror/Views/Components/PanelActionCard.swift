import SwiftUI

/// 菜单栏面板里的入口卡片：图标在上、文字在下，**整块**都是命中区。
/// 取代原来的一行文字按钮——那种只有文字本身可点，在弹出面板里很容易点空。
struct PanelActionCard: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: Theme.Metrics.iconVisual))
                Text(title)
                    .font(Theme.Typography.body)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, Theme.Spacing.sm)
            .foregroundStyle(role == .destructive ? Theme.Palette.danger : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.quick(reduceMotion), value: isHovering)
        .accessibilityLabel(title)
    }

    /// hover 时混入更多前景色（不透明），而不是给底色叠 `.opacity()`——
    /// 原实现用 `.opacity(isHovering ? 1.6 : 1)`：opacity 上限是 1，
    /// 1.6 会被直接钳到 1，跟未 hover 时完全一样，hover 视觉上没有任何反馈。
    private var backgroundColor: Color {
        let base = role == .destructive ? Theme.Palette.danger : Color.gray
        return isHovering ? Theme.Palette.blend(base, into: Theme.Palette.panel, fraction: 0.2) : Theme.Palette.tint(base)
    }
}

#Preview {
    HStack(spacing: Theme.Spacing.sm) {
        PanelActionCard(title: "配置", systemImage: "slider.horizontal.3") {}
        PanelActionCard(title: "诊断", systemImage: "stethoscope") {}
        PanelActionCard(title: "退出", systemImage: "power", role: .destructive) {}
    }
    .padding()
    .frame(width: 300)
}
