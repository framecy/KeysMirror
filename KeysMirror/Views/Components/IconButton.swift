import SwiftUI

/// 统一的图标按钮：视觉是一个小图标，但命中区始终 ≥ `Theme.Metrics.minHitTarget`，
/// hover 时给出背景反馈。全 App 的图标操作都走这个组件，尺寸与反馈一致。
struct IconButton: View {
    let systemName: String
    let help: String
    var role: ButtonRole?
    var size: CGFloat = Theme.Metrics.minHitTarget
    var iconSize: CGFloat = Theme.Metrics.iconVisual
    var isProminent: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .onHover { isHovering = $0 && isEnabled }
        .animation(Theme.Motion.quick(reduceMotion), value: isHovering)
        .help(help)
        .accessibilityLabel(help)
    }

    private var background: Color {
        Self.background(isHovering: isHovering, role: role)
    }

    /// 抽成 static：`Menu` 的标签没法复用 `IconButton` 本体（它自带 Button），
    /// 但必须复用同一套配色与 hover 反馈，否则并排放在工具栏里一眼就能看出风格不一致。
    static func background(isHovering: Bool, role: ButtonRole? = nil) -> Color {
        guard isHovering else { return .clear }
        return Theme.Palette.tint(role == .destructive ? Theme.Palette.danger : Theme.Palette.accent)
    }

    static func foreground(isHovering: Bool) -> Color {
        isHovering ? .primary : .secondary
    }

    private var foreground: Color {
        if !isEnabled { return Theme.Palette.blend(Color(nsColor: .labelColor), into: Theme.Palette.panel, fraction: 0.35) }
        if role == .destructive { return isHovering ? Theme.Palette.danger : .secondary }
        if isProminent { return Theme.Palette.accent }
        return isHovering ? .primary : .secondary
    }
}

#Preview {
    HStack(spacing: Theme.Spacing.sm) {
        IconButton(systemName: "plus", help: "添加") {}
        IconButton(systemName: "pencil", help: "编辑") {}
        IconButton(systemName: "trash", help: "删除", role: .destructive) {}
    }
    .padding()
}
