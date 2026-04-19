import SwiftUI

struct MappingListView: View {
    let profile: AppProfile
    let onEdit: (KeyMapping) -> Void
    let onDelete: (KeyMapping) -> Void
    let onToggleEnabled: (KeyMapping) -> Void

    var body: some View {
        if profile.mappings.isEmpty {
            EmptyStateView(
                title: "还没有映射",
                systemImage: "keyboard",
                description: "创建一条映射后，录制目标应用窗口中的点击位置。"
            )
        } else {
            List(profile.mappings) { mapping in
                HStack(spacing: 12) {
                    Toggle("", isOn: Binding(
                        get: { mapping.isEnabled },
                        set: { _ in onToggleEnabled(mapping) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(mapping.isEnabled ? "已启用，点击禁用" : "已禁用，点击启用")

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(mapping.label)
                                .font(.headline)
                            scaleBadge(for: mapping)
                        }
                        Text(mapping.displayShortcut)
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
                .opacity(mapping.isEnabled ? 1.0 : 0.55)
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func scaleBadge(for mapping: KeyMapping) -> some View {
        if mapping.hasScaleReference {
            Text("缩放跟随")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.18))
                .foregroundStyle(.green)
                .clipShape(Capsule())
                .help("已记录窗口尺寸快照，目标窗口缩放时点击位置按比例换算")
        } else {
            Text("v1.2 旧映射")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.18))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
                .help("没有窗口尺寸快照，缩放后会偏；编辑并重新录制位置即可启用缩放跟随")
        }
    }
}
