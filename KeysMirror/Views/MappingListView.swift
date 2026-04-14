import SwiftUI

struct MappingListView: View {
    let profile: AppProfile
    let onEdit: (KeyMapping) -> Void
    let onDelete: (KeyMapping) -> Void

    var body: some View {
        if profile.mappings.isEmpty {
            EmptyStateView(
                title: "还没有映射",
                systemImage: "keyboard",
                description: "创建一条映射后，录制目标应用窗口中的点击位置。"
            )
        } else {
            List(profile.mappings) { mapping in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mapping.label)
                            .font(.headline)
                        Text(CGKeyCodeNames.shortcutLabel(for: mapping.keyCode, modifiers: mapping.modifiers))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("(\(Int(mapping.relativeX)), \(Int(mapping.relativeY)))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Button("编辑") {
                        onEdit(mapping)
                    }

                    Button("删除", role: .destructive) {
                        onDelete(mapping)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
