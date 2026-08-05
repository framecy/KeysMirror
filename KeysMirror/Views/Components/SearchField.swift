import SwiftUI

/// 内容区内联搜索框。
///
/// 不用 `.searchable(placement: .toolbar)`：工具栏一挤（窗口变窄 / 工具栏项多）
/// 搜索框会被系统折叠掉甚至看不见，而搜索是这里的高频操作，必须常驻可见。
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "搜索名称或键位"

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(height: Theme.Metrics.minHitTarget)
        .background(Theme.Palette.tint(.gray), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(Theme.Palette.separator, lineWidth: 1)
        )
    }
}
