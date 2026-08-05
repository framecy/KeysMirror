import SwiftUI

/// 胶囊徽标：「缩放跟随」「v1.2 旧映射」「连击 ×2」等。
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(Theme.Typography.label)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 2)
        .background(Theme.Palette.tint(color), in: Capsule())
        .foregroundStyle(color)
    }
}

/// 区块标题 + 右侧操作位。
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.section)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// `surface` 底 + 中圆角 + 标准内边距的容器。
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.md
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        HStack {
            Badge(text: "缩放跟随", color: Theme.Palette.success, systemImage: "arrow.up.left.and.arrow.down.right")
            Badge(text: "v1.2 旧映射")
            Badge(text: "连击 ×2", color: Theme.Palette.accent)
        }
        Card {
            SectionHeader(title: "步骤", subtitle: "按顺序执行") {
                Button("新增") {}
            }
        }
    }
    .padding()
}
