import SwiftUI

/// 映射行与宏行共用的行组件（**两个列表仍然各自独立**，只是复用同一套行视觉）。
///
/// 命中区规范（见 Theme.Metrics.minHitTarget）：
/// - 启停：状态点视觉 10pt，但外层是 28×28 的按钮
/// - 编辑 / 复制 / 删除：IconButton，各 28×28，hover 才浮出
/// - 整行 hover 高亮，双击 = 编辑（不必去瞄那个小铅笔）
struct ActionRow<Badges: View>: View {
    let title: String
    let trigger: KeyCapView.Trigger
    /// 右侧摘要：映射给坐标，宏给「3 步 × 无限循环」
    let summary: String
    let state: StatusDot.State
    @ViewBuilder var badges: () -> Badges

    var onToggleEnabled: () -> Void
    var onEdit: () -> Void
    var onDuplicate: (() -> Void)?
    var onDelete: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button(action: onToggleEnabled) {
                StatusDot(state: state)
                    .frame(width: Theme.Metrics.minHitTarget, height: Theme.Metrics.minHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state == .disabled ? "已禁用，点击启用" : "已启用，点击禁用")

            // 键帽单独成列：所有行的键位纵向对齐，一眼扫得下来
            KeyCapView(trigger: trigger)
                .frame(width: Theme.Metrics.keyCapColumnWidth, alignment: .leading)

            HStack(spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(Theme.Typography.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                badges()
            }

            Spacer(minLength: Theme.Spacing.sm)

            Text(summary)
                .font(Theme.Typography.mono)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 2) {
                IconButton(systemName: "pencil", help: "编辑", action: onEdit)
                if let onDuplicate {
                    IconButton(systemName: "plus.square.on.square", help: "复制", action: onDuplicate)
                }
                IconButton(systemName: "trash", help: "删除", role: .destructive, action: onDelete)
            }
            .opacity(isHovering ? 1 : 0)
            .animation(Theme.Motion.quick(reduceMotion), value: isHovering)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: Theme.Metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isHovering ? Theme.Palette.tint(.gray) : .clear)
        )
        .contentShape(Rectangle())
        // 禁用态不用整体透明（会透出下层），改成灰字 + 空心状态点
        .foregroundStyle(state == .disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .onHover { isHovering = $0 }
        // 整行双击即编辑：比瞄准行尾的小图标可靠得多
        .onTapGesture(count: 2) { onEdit() }
    }
}

extension ActionRow where Badges == EmptyView {
    init(
        title: String,
        trigger: KeyCapView.Trigger,
        summary: String,
        state: StatusDot.State,
        onToggleEnabled: @escaping () -> Void,
        onEdit: @escaping () -> Void,
        onDuplicate: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) {
        self.init(
            title: title,
            trigger: trigger,
            summary: summary,
            state: state,
            badges: { EmptyView() },
            onToggleEnabled: onToggleEnabled,
            onEdit: onEdit,
            onDuplicate: onDuplicate,
            onDelete: onDelete
        )
    }
}
