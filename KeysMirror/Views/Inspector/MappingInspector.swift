import SwiftUI

/// 映射 Inspector：即时保存（见 docs/UI-Redesign.md 6.3）。
struct MappingInspector: View {
    @StateObject private var viewModel: MappingEditorViewModel
    @State private var showAdvanced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(profile: AppProfile, mapping: KeyMapping?) {
        _viewModel = StateObject(
            wrappedValue: MappingEditorViewModel(profile: profile, existingMapping: mapping, autosave: true)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header

                if let hint = viewModel.draftHint {
                    Label(hint, systemImage: "pencil.and.outline")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }

                triggerSection
                positionSection
                advancedSection

                if let message = viewModel.message {
                    Text(message)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .onDisappear {
            viewModel.stopRecording()
            // 编辑器消失后，栈里不该再留着指向它的字段级撤销记录
            viewModel.discardUndoHistory()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("映射")
                .font(Theme.Typography.title)
            TextField("名称", text: $viewModel.label)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "触发")
            HStack {
                KeyCapView(trigger: viewModel.capTrigger)
                Spacer()
                RecordButton(
                    phase: viewModel.isRecordingTrigger ? .waiting : (viewModel.justCaptured ? .captured : .idle),
                    idleTitle: "录制触发",
                    waitingTitle: "按下按键…",
                    systemImage: "keyboard"
                ) {
                    viewModel.startTriggerRecording()
                }
                            }
            Text("按下键盘快捷键，或点击鼠标右键 / 侧键。")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var positionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "点击位置", subtitle: viewModel.pointText)

            PositionCanvas(
                point: Binding(
                    get: { viewModel.recordedPoint },
                    set: { if let p = $0 { viewModel.updatePoint(p) } }
                ),
                referenceSize: viewModel.recordedReferenceSize,
                otherPoints: otherPoints,
                isRecording: viewModel.isRecordingPoint
            )

            HStack {
                RecordButton(
                    phase: viewModel.isRecordingPoint ? .waiting : (viewModel.justCaptured ? .captured : .idle),
                    idleTitle: "录制位置",
                    waitingTitle: "等待点击…",
                    systemImage: "scope"
                ) {
                    viewModel.startPointRecording()
                }
                                Spacer()
                // 与列表同一规范：只标例外，正常的「缩放跟随」不加徽标
                if viewModel.recordedReferenceSize == nil, viewModel.recordedPoint != nil {
                    Badge(text: "无缩放参考", color: Theme.Palette.warning, systemImage: "exclamationmark.triangle.fill")
                        .help("没有窗口尺寸快照，缩放后会偏；重新录制位置即可启用缩放跟随")
                }
            }
            Text("拖动画布上的红点可直接微调坐标。")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(Theme.Motion.standard(reduceMotion)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("高级")
                }
                .font(Theme.Typography.section)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                Toggle("拦截原始按键（推荐）", isOn: $viewModel.blockInput)
                    .toggleStyle(.switch)
                                        .help("关闭后按键会同时触发点击并传递给目标应用，适合需要在聊天框里打字的场景")
                if let size = viewModel.recordedReferenceSize {
                    Text("录制时窗口尺寸：\(Int(size.width)) × \(Int(size.height))")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var otherPoints: [(point: CGPoint, label: String)] {
        viewModel.profile.mappings
            .filter { $0.id != viewModel.existingMapping?.id }
            .map { (CGPoint(x: $0.relativeX, y: $0.relativeY), $0.label) }
    }
}
