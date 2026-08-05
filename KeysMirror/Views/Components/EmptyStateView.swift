import SwiftUI

/// 空状态：图标 + 标题 + 说明 +（可选）主操作。
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .padding(.bottom, Theme.Spacing.xs)
            Text(title)
                .font(.headline)
            Text(description)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    EmptyStateView(
        title: "还没有映射",
        systemImage: "keyboard",
        description: "创建一条映射后，录制目标应用窗口中的点击位置。",
        actionTitle: "新建映射",
        action: {}
    )
    .frame(width: 480, height: 300)
}
