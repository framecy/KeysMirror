import SwiftUI

/// 宏 Inspector：即时保存 + 可拖拽排序的折叠步骤列表。
struct MacroInspector: View {
    @StateObject private var viewModel: MacroEditorViewModel
    @ObservedObject private var macroRunner = MacroRunner.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 正在编辑的宏 id；运行中的宏不允许编辑，用它来判定
    private let editingMacroId: UUID?

    init(profile: AppProfile, macro: MacroAction?, onFirstCommit: ((MacroAction) -> Void)? = nil) {
        self.editingMacroId = macro?.id
        let vm = MacroEditorViewModel(profile: profile, existingMacro: macro, autosave: false)
        vm.onFirstCommit = onFirstCommit
        _viewModel = StateObject(wrappedValue: vm)
    }

    /// 运行中的宏禁止编辑：一边跑一边改配置，执行器每轮重读到的定义会前后不一致，
    /// 行为无法预期（用户也反馈过在这种情况下闪退）。要改先停。
    private var isRunning: Bool {
        guard let editingMacroId else { return false }
        return macroRunner.isRunning(editingMacroId)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isRunning {
                Label("这个宏正在运行，停止后才能编辑", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.md)
                    .background(Theme.Palette.tint(Theme.Palette.warning))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header

                    if let hint = viewModel.draftHint {
                        Label(hint, systemImage: "pencil.and.outline")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.warning)
                    }

                    triggerSection
                    repeatSection
                    stepsSection

                    if let message = viewModel.message {
                        Text(message)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Theme.Spacing.lg)
            }

            .disabled(isRunning)

            Divider()
            footerBar
        }
        .onDisappear {
            viewModel.stopRecording()
            // 编辑器消失后，栈里不该再留着指向它的步骤级撤销记录
            viewModel.discardStepUndoHistory()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("宏")
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
        }
    }

    private static let repeatModes: [MacroEditorViewModel.RepeatMode] = [.once, .count, .infinite]

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            SectionHeader(title: "重复")
            SegmentedTabs(
                titles: ["单次", "N 次", "无限"],
                selectedIndex: Self.repeatModes.firstIndex(of: viewModel.repeatMode) ?? 0,
                onSelect: { viewModel.repeatMode = Self.repeatModes[$0] }
            )

            if viewModel.repeatMode == .count {
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("", value: $viewModel.repeatCountText, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .monospacedDigit()
                    Stepper("", value: $viewModel.repeatCountText, in: 2...9999)
                        .labelsHidden()
                    Text("次后自动停止")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(viewModel.repeatMode == .infinite ? "运行后再按触发键停止" : "执行一次后结束")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // 录制是宏最主要的入口，给整块大按钮（44pt 高，整块可点），不再是行尾的小图标
            Button {
                viewModel.toggleSequenceRecording()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: viewModel.isRecordingSequence ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(viewModel.isRecordingSequence ? "结束录制" : "录制点击序列")
                            .font(Theme.Typography.section)
                        Text(viewModel.isRecordingSequence
                             ? "已记录 \(viewModel.recordedClickCount) 次点击 · 按 Esc 结束"
                             : "切到 \(viewModel.profile.appName) 后点击，自动记录位置、间隔与连击")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Palette.tint(viewModel.isRecordingSequence ? Theme.Palette.danger : Theme.Palette.accent))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(viewModel.isRecordingSequence ? Theme.Palette.danger : Theme.Palette.accent, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.isRecordingSequence ? Theme.Palette.danger : Theme.Palette.accent)

            SectionHeader(title: "步骤 (\(viewModel.steps.count))", subtitle: "点卡片展开 · 展开后可上下移动") {
                Button {
                    withAnimation(Theme.Motion.standard(reduceMotion)) { viewModel.addStep() }
                } label: {
                    Label("新增", systemImage: "plus")
                }
            }

            if viewModel.steps.isEmpty {
                Text("还没有步骤。直接录制一段点击序列，或手动新增。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.Spacing.lg)
            } else {
                // 用 VStack 而不是 List：
                // 1) List 的行手势会吃掉卡片上的点击，导致「点了不展开」；
                // 2) ScrollView 里再嵌一个可滚动 List 本身就是错的（两层滚动 + 固定高度）。
                // 排序改用每行的上下箭头，行为明确、不跟点击抢手势。
                VStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                        MacroStepCard(
                            index: index,
                            // 按 id 取绑定，不用 `$viewModel.steps[index]`。
                            // 删除 / 撤销带动画时，SwiftUI 会在过渡期间再求值一次已经移除的行，
                            // 那时下标已经越界，数组下标直接 trap。按 id 找不到就退回快照值。
                            step: stepBinding(for: step),
                            profileMappings: viewModel.profile.mappings,
                            isRecordingThisStep: viewModel.recordingStepId == step.id,
                            canMoveUp: index > 0,
                            canMoveDown: index < viewModel.steps.count - 1,
                            onRecord: { viewModel.startPointRecording(forStepId: step.id) },
                            onMoveUp: { withAnimation(Theme.Motion.standard(reduceMotion)) { viewModel.moveStep(from: index, to: index - 1) } },
                            onMoveDown: { withAnimation(Theme.Motion.standard(reduceMotion)) { viewModel.moveStep(from: index, to: index + 1) } },
                            onDuplicate: { viewModel.duplicateStep(at: index) },
                            onDelete: { withAnimation(Theme.Motion.standard(reduceMotion)) { viewModel.removeStep(at: index) } }
                        )
                    }
                }
            }
        }
    }

    /// 以 id 为锚的步骤绑定：写回时重新按 id 定位，行已经不在就丢弃这次写入。
    private func stepBinding(for snapshot: EditableStep) -> Binding<EditableStep> {
        let vm = viewModel
        return Binding(
            get: { vm.steps.first { $0.id == snapshot.id } ?? snapshot },
            set: { newValue in
                guard let idx = vm.steps.firstIndex(where: { $0.id == snapshot.id }) else { return }
                vm.steps[idx] = newValue
            }
        )
    }

    /// 常驻底栏：「拦截原始按键」是每次调宏都要确认的开关，
    /// 折进「高级」里既多一次点击、又容易被忽略，直接钉在窗口底部。
    private var footerBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle("拦截原始按键", isOn: $viewModel.blockInput)
                .toggleStyle(.switch)

            Text(viewModel.blockInput
                 ? "触发键不会再传给目标应用（推荐）"
                 : "触发键会同时传给目标应用，适合要在聊天框打字的场景")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            // 显式保存：编辑器不再即时写库。
            // 即时保存会在「宏正在运行」时把半成品配置灌进执行器（执行器每轮重读定义），
            // 也让撤销粒度碎到每次敲键，改成攒一批一次提交。
            if viewModel.hasUnsavedChanges {
                Text("未保存")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
            Button("保存") { _ = viewModel.commit() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || !viewModel.hasUnsavedChanges)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(minHeight: 52)
        .background(Theme.Palette.panel)
    }
}

// MARK: - 步骤卡片

/// 一步 = 一张卡片：**整张卡片**点击展开／收起（不再是行首那个小箭头）。
private struct MacroStepCard: View {
    let index: Int
    @Binding var step: EditableStep
    let profileMappings: [KeyMapping]
    let isRecordingThisStep: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRecord: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            summaryRow
            if step.isExpanded {
                Divider()
                detail
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(isHovering ? Theme.Palette.tint(.gray) : Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(step.isExpanded ? Theme.Palette.accent : Theme.Palette.separator, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    /// 摘要行：整块（含空白处）都可点，命中区 32pt 起
    private var summaryRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("\(index + 1)")
                .font(Theme.Typography.section)
                .monospacedDigit()
                .frame(width: Theme.Metrics.stepIndexBadgeSize, height: Theme.Metrics.stepIndexBadgeSize)
                .background(Circle().fill(Theme.Palette.tint(Theme.Palette.accent)))

            Text(step.summary)
                .font(Theme.Typography.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.sm)

            Image(systemName: "chevron.right")
                .font(Theme.Typography.body)
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(step.isExpanded ? 90 : 0))
                .frame(width: 20)
        }
        .frame(minHeight: Theme.Metrics.minHitTarget)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Theme.Motion.standard(reduceMotion)) { step.isExpanded.toggle() }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("第 \(index + 1) 步，\(step.summary)")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Text("延迟").font(Theme.Typography.body)
                TextField("", value: $step.delayValue, format: .number)
                    .frame(width: 72)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .monospacedDigit()
                Picker("", selection: $step.delayUnit) {
                    Text("秒").tag(DelayUnit.seconds)
                    Text("分").tag(DelayUnit.minutes)
                }
                .labelsHidden()
                .controlSize(.large)
                .frame(width: 80)

                Spacer(minLength: Theme.Spacing.sm)

                Text("连击").font(Theme.Typography.body)
                TextField("", value: $step.clickCount, format: .number)
                    .frame(width: 56)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .monospacedDigit()
                Stepper("", value: $step.clickCount, in: 1...20)
                    .labelsHidden()
            }

            SegmentedTabs(
                titles: ["现场录制", "引用映射"],
                selectedIndex: step.sourceKind == .inline ? 0 : 1,
                onSelect: { step.sourceKind = $0 == 0 ? .inline : .mapping }
            )

            positionDetail
            driftDetail

            Divider()

            HStack(spacing: 2) {
                IconButton(systemName: "arrow.up", help: "上移") { onMoveUp() }
                    .disabled(!canMoveUp)
                IconButton(systemName: "arrow.down", help: "下移") { onMoveDown() }
                    .disabled(!canMoveDown)
                Spacer()
                IconButton(systemName: "plus.square.on.square", help: "复制此步", action: onDuplicate)
                IconButton(systemName: "trash", help: "删除此步", role: .destructive, action: onDelete)
            }
        }
    }

    @ViewBuilder
    private var positionDetail: some View {
        switch step.sourceKind {
        case .mapping:
            if profileMappings.isEmpty {
                Text("当前 profile 没有映射可引用。")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.warning)
            } else {
                Picker("位置", selection: $step.referencedMappingId) {
                    Text("（未选择）").tag(UUID?.none)
                    ForEach(profileMappings) { m in
                        Text("\(m.label) · \(m.displayShortcut)").tag(Optional(m.id))
                    }
                }
                .labelsHidden()
                .controlSize(.large)
            }
        case .inline:
            HStack(spacing: Theme.Spacing.sm) {
                if let p = step.inlinePoint {
                    Text("(x: \(Int(p.x)), y: \(Int(p.y)))")
                        .font(Theme.Typography.mono)
                } else {
                    Text("未录制")
                        .font(Theme.Typography.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RecordButton(
                    phase: isRecordingThisStep ? .waiting : .idle,
                    idleTitle: "录制位置",
                    waitingTitle: "等待点击…",
                    systemImage: "scope",
                    action: onRecord
                )
            }
        }
    }

    private var driftDetail: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Toggle("区域漂移", isOn: Binding(
                get: { step.driftPercent > 0 },
                set: { step.driftPercent = $0 ? (step.driftPercent > 0 ? step.driftPercent : 1) : 0 }
            ))
            .toggleStyle(.checkbox)
            .font(Theme.Typography.body)
            .help("每次点击在录制点周围随机漂移，避免每次点在完全相同的像素上")

            if step.driftPercent > 0 {
                TextField("", value: $step.driftPercent, format: .number)
                    .frame(width: 60)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .monospacedDigit()
                Stepper("", value: $step.driftPercent, in: 0.1...50, step: 0.5)
                    .labelsHidden()
                Text("% 窗口尺寸")
                    .font(Theme.Typography.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

