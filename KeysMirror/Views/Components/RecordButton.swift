import SwiftUI

/// 录制按钮的三态机：待命 / 等待输入（脉冲）/ 刚捕获（成功一闪）。
struct RecordButton: View {
    enum Phase: Hashable {
        case idle
        case waiting
        case captured
    }

    let phase: Phase
    var idleTitle: String = "录制"
    var waitingTitle: String = "等待输入…"
    var systemImage: String = "record.circle"
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: phase == .captured ? "checkmark.circle.fill" : systemImage)
                Text(phase == .waiting ? waitingTitle : idleTitle)
            }
            .opacity(phase == .waiting && pulsing && !reduceMotion ? 0.55 : 1)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .animation(Theme.Motion.ambient(reduceMotion), value: pulsing)
        .animation(Theme.Motion.standard(reduceMotion), value: phase)
        .onAppear { pulsing = phase == .waiting }
        .onChange(of: phase) { newValue in pulsing = newValue == .waiting }
        .accessibilityLabel(phase == .waiting ? waitingTitle : idleTitle)
    }

    private var tint: Color {
        switch phase {
        case .idle: return Theme.Palette.accent
        case .waiting: return Theme.Palette.danger
        case .captured: return Theme.Palette.success
        }
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.md) {
        RecordButton(phase: .idle) {}
        RecordButton(phase: .waiting) {}
        RecordButton(phase: .captured) {}
    }
    .padding()
}
