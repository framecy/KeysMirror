import AppKit
import SwiftUI

struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MacroEditorViewModel

    init(profile: AppProfile, existingMacro: MacroAction?) {
        _viewModel = StateObject(wrappedValue: MacroEditorViewModel(profile: profile, existingMacro: existingMacro))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(viewModel.existingMacro == nil ? "新建宏" : "编辑宏")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") {
                    viewModel.stopRecording()
                    dismiss()
                }
            }

            TextField("标签名称", text: $viewModel.label)
                .textFieldStyle(.roundedBorder)

            triggerSection
            repeatSection
            stepsSection

            if let message = viewModel.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button("取消") {
                    viewModel.stopRecording()
                    dismiss()
                }
                Spacer()
                Button(viewModel.existingMacro == nil ? "保存宏" : "更新宏") {
                    if viewModel.save() { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSave)
            }
        }
        .padding(20)
        .frame(width: 620, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Sections

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("触发方式")
                .font(.headline)
            HStack {
                Text(viewModel.shortcutText)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button(viewModel.isRecordingTrigger ? "录制中..." : "录制触发") {
                    viewModel.startTriggerRecording()
                }
                .buttonStyle(.borderedProminent)
            }
            Text("点击「录制触发」后，按下键盘快捷键，或点击鼠标右键、侧键。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Toggle("拦截原始按键（推荐）", isOn: $viewModel.blockInput)
                .toggleStyle(.switch)
                .help("关闭后按键会同时触发宏并传递给目标应用")
        }
    }

    private var repeatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("重复次数")
                .font(.headline)
            HStack(spacing: 12) {
                Toggle("无限循环", isOn: $viewModel.isInfinite)
                    .toggleStyle(.switch)

                if !viewModel.isInfinite {
                    Stepper(value: $viewModel.repeatCountText, in: 1...9999, step: 1) {
                        HStack(spacing: 4) {
                            Text("执行")
                            TextField("", value: $viewModel.repeatCountText, format: .number)
                                .frame(width: 60)
                                .textFieldStyle(.roundedBorder)
                            Text("次")
                        }
                    }
                }
            }
            Text(viewModel.isInfinite ? "运行后再按触发键停止" : "执行 \(viewModel.repeatCountText) 次后自动停止；运行中按触发键可提前终止")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("步骤（按顺序执行）")
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.addStep()
                } label: {
                    Label("新增步骤", systemImage: "plus")
                }
                .controlSize(.small)
            }

            if viewModel.steps.isEmpty {
                Text("还没有步骤。每一步可以引用现有映射，或现场录制一个位置。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                            StepRow(
                                index: index,
                                step: $viewModel.steps[index],
                                profileMappings: viewModel.profile.mappings,
                                isRecordingThisStep: viewModel.recordingStepId == step.id,
                                onRecord: { viewModel.startPointRecording(forStepId: step.id) },
                                onMoveUp: index > 0 ? { viewModel.moveStep(from: index, to: index - 1) } : nil,
                                onMoveDown: index < viewModel.steps.count - 1 ? { viewModel.moveStep(from: index, to: index + 1) } : nil,
                                onDelete: { viewModel.removeStep(at: index) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }
}

// MARK: - Step row

private struct StepRow: View {
    let index: Int
    @Binding var step: EditableStep
    let profileMappings: [KeyMapping]
    let isRecordingThisStep: Bool
    let onRecord: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1).")
                .font(.subheadline.weight(.medium))
                .frame(width: 24, alignment: .trailing)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("延迟")
                        .font(.caption)
                    TextField("", value: $step.delayValue, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $step.delayUnit) {
                        Text("秒").tag(DelayUnit.seconds)
                        Text("分").tag(DelayUnit.minutes)
                    }
                    .labelsHidden()
                    .frame(width: 70)

                    Spacer()

                    Picker("", selection: $step.sourceKind) {
                        Text("引用映射").tag(StepSourceKind.mapping)
                        Text("现场录制").tag(StepSourceKind.inline)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }

                positionDetail
            }

            VStack(spacing: 2) {
                Button { onMoveUp?() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.plain)
                    .disabled(onMoveUp == nil)
                Button { onMoveDown?() } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.plain)
                    .disabled(onMoveDown == nil)
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(8)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var positionDetail: some View {
        switch step.sourceKind {
        case .mapping:
            if profileMappings.isEmpty {
                Text("当前 profile 没有映射可引用，先去映射列表创建一条。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Picker("位置", selection: $step.referencedMappingId) {
                    Text("（未选择）").tag(UUID?.none)
                    ForEach(profileMappings) { m in
                        Text("\(m.label) · \(m.displayShortcut) · (\(Int(m.relativeX)),\(Int(m.relativeY)))")
                            .tag(Optional(m.id))
                    }
                }
                .labelsHidden()
            }
        case .inline:
            HStack(spacing: 8) {
                if let p = step.inlinePoint {
                    Text("(x: \(Int(p.x)), y: \(Int(p.y)))")
                        .font(.system(.caption, design: .monospaced))
                } else {
                    Text("未录制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isRecordingThisStep ? "等待点击..." : "录制位置") {
                    onRecord()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Editable structs (UI-side, not persisted directly)

enum DelayUnit: String, Hashable {
    case seconds, minutes
}

enum StepSourceKind: String, Hashable {
    case mapping, inline
}

struct EditableStep: Identifiable, Hashable {
    let id: UUID
    var delayValue: Double
    var delayUnit: DelayUnit
    var sourceKind: StepSourceKind
    var referencedMappingId: UUID?
    var inlinePoint: CGPoint?
    var inlineReferenceSize: CGSize?

    init(id: UUID = UUID(), step: MacroStep? = nil) {
        self.id = step?.id ?? id
        let delaySeconds = step?.delaySeconds ?? 0
        // 默认以秒展示；超过 60 秒且能整除则以分展示，方便阅读
        if delaySeconds > 0 && delaySeconds.truncatingRemainder(dividingBy: 60) == 0 && delaySeconds >= 60 {
            self.delayValue = delaySeconds / 60
            self.delayUnit = .minutes
        } else {
            self.delayValue = delaySeconds
            self.delayUnit = .seconds
        }
        switch step?.position {
        case .mapping(let id):
            self.sourceKind = .mapping
            self.referencedMappingId = id
            self.inlinePoint = nil
            self.inlineReferenceSize = nil
        case .inline(let x, let y, let refW, let refH):
            self.sourceKind = .inline
            self.referencedMappingId = nil
            self.inlinePoint = CGPoint(x: x, y: y)
            if let refW, let refH {
                self.inlineReferenceSize = CGSize(width: refW, height: refH)
            }
        case .none:
            self.sourceKind = .mapping
            self.referencedMappingId = nil
        }
    }

    var delaySecondsValue: Double {
        delayUnit == .seconds ? delayValue : delayValue * 60
    }

    func toMacroStep() -> MacroStep? {
        let pos: MacroStepPosition
        switch sourceKind {
        case .mapping:
            guard let id = referencedMappingId else { return nil }
            pos = .mapping(id)
        case .inline:
            guard let p = inlinePoint else { return nil }
            pos = .inline(
                relativeX: p.x,
                relativeY: p.y,
                referenceWidth: inlineReferenceSize?.width,
                referenceHeight: inlineReferenceSize?.height
            )
        }
        return MacroStep(id: id, delaySeconds: max(0, delaySecondsValue), position: pos)
    }
}

// MARK: - View Model

@MainActor
final class MacroEditorViewModel: ObservableObject {
    @Published var label: String
    @Published var blockInput: Bool
    @Published var isInfinite: Bool
    @Published var repeatCountText: Int
    @Published var steps: [EditableStep]
    @Published var recordedKeyCode: UInt16?
    @Published var recordedModifiers: UInt64
    @Published var recordedTriggerType: TriggerType
    @Published var recordedMouseButtonNumber: Int?
    @Published var isRecordingTrigger = false
    @Published var recordingStepId: UUID?
    @Published var message: String?

    let profile: AppProfile
    let existingMacro: MacroAction?

    private let appResolver = AppResolver.shared
    private let pointRecorder = PointRecorder.shared
    private let triggerRecorder = TriggerRecorder.shared

    init(profile: AppProfile, existingMacro: MacroAction?) {
        self.profile = profile
        self.existingMacro = existingMacro
        self.label = existingMacro?.label ?? ""
        self.blockInput = existingMacro?.blockInput ?? true
        let count = existingMacro?.repeatCount ?? 1
        self.isInfinite = count == 0
        self.repeatCountText = count == 0 ? 1 : count
        self.steps = (existingMacro?.steps ?? []).map { EditableStep(step: $0) }
        self.recordedKeyCode = existingMacro?.keyCode
        self.recordedModifiers = existingMacro?.modifiers ?? 0
        self.recordedTriggerType = existingMacro?.triggerType ?? .keyboard
        self.recordedMouseButtonNumber = existingMacro?.mouseButtonNumber
    }

    var shortcutText: String {
        switch recordedTriggerType {
        case .keyboard:
            guard let recordedKeyCode else { return "未录制" }
            return CGKeyCodeNames.shortcutLabel(for: recordedKeyCode, modifiers: recordedModifiers)
        case .mouseRight:
            return "鼠标右键"
        case .mouseOther:
            if let num = recordedMouseButtonNumber { return "鼠标按键 \(num)" }
            return "鼠标多功能键"
        }
    }

    var canSave: Bool {
        let hasTrigger: Bool
        switch recordedTriggerType {
        case .keyboard: hasTrigger = recordedKeyCode != nil
        case .mouseRight: hasTrigger = true
        case .mouseOther: hasTrigger = recordedMouseButtonNumber != nil
        }
        let allStepsValid = !steps.isEmpty && steps.allSatisfy { $0.toMacroStep() != nil }
        return hasTrigger && allStepsValid && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func addStep() {
        steps.append(EditableStep())
    }

    func removeStep(at index: Int) {
        guard steps.indices.contains(index) else { return }
        steps.remove(at: index)
    }

    func moveStep(from: Int, to: Int) {
        guard steps.indices.contains(from), to >= 0, to < steps.count else { return }
        let item = steps.remove(at: from)
        steps.insert(item, at: to)
    }

    func startTriggerRecording() {
        stopTriggerRecording()
        isRecordingTrigger = true
        message = "按下键盘按键，或点击鼠标右键、多功能键。"

        _ = triggerRecorder.start { [weak self] trigger in
            guard let self else { return }
            switch trigger {
            case .keyboard(let keyCode, let modifiers):
                self.recordedTriggerType = .keyboard
                self.recordedKeyCode = keyCode
                self.recordedModifiers = modifiers
                self.recordedMouseButtonNumber = nil
                if self.label.isEmpty { self.label = "宏 \(CGKeyCodeNames.name(for: keyCode))" }
            case .mouseRight:
                self.recordedTriggerType = .mouseRight
                self.recordedKeyCode = 0
                self.recordedModifiers = 0
                self.recordedMouseButtonNumber = nil
                if self.label.isEmpty { self.label = "宏 鼠标右键" }
            case .mouseOther(let buttonNumber):
                self.recordedTriggerType = .mouseOther
                self.recordedMouseButtonNumber = buttonNumber
                self.recordedKeyCode = 0
                self.recordedModifiers = 0
                if self.label.isEmpty { self.label = "宏 鼠标按键 \(buttonNumber)" }
            }
            self.isRecordingTrigger = false
            self.message = nil
        }
    }

    func startPointRecording(forStepId stepId: UUID) {
        stopPointRecording()

        guard let targetApp = appResolver.runningApplication(bundleIdentifier: profile.bundleIdentifier) else {
            message = "\(profile.appName) 当前没有运行。"
            return
        }

        recordingStepId = stepId
        message = "正在激活 \(profile.appName)，请在目标窗口中点击一次。"

        let started = pointRecorder.start { [weak self] point in
            guard let self else { return }
            self.capturePoint(at: point, stepId: stepId)
        }
        guard started else {
            recordingStepId = nil
            message = "无法启动点击录制，请确认已经授予辅助功能权限。"
            return
        }

        ConfigurationWindowController.shared.hide()
        NSApp.deactivate()
        targetApp.unhide()
        activateTargetApplication(retryCount: 3)
    }

    func save() -> Bool {
        guard canSave else { return false }

        let macroSteps = steps.compactMap { $0.toMacroStep() }
        guard macroSteps.count == steps.count else {
            message = "存在尚未配置完成的步骤"
            return false
        }

        let macro = MacroAction(
            id: existingMacro?.id ?? UUID(),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            triggerType: recordedTriggerType,
            keyCode: recordedKeyCode ?? 0,
            modifiers: recordedModifiers,
            mouseButtonNumber: recordedMouseButtonNumber,
            blockInput: blockInput,
            isEnabled: existingMacro?.isEnabled ?? true,
            repeatCount: isInfinite ? 0 : max(1, repeatCountText),
            steps: macroSteps
        )

        let conflict = MappingStore.shared.hasDuplicateTrigger(
            triggerType: macro.triggerType,
            keyCode: macro.keyCode,
            modifiers: macro.modifiers,
            mouseButtonNumber: macro.mouseButtonNumber,
            in: profile,
            excludingMacroId: existingMacro?.id
        )
        if conflict {
            message = "已存在同触发的映射或宏，请更换按键。"
            return false
        }

        if existingMacro == nil {
            MappingStore.shared.addMacro(macro, to: profile)
        } else {
            MappingStore.shared.updateMacro(macro, in: profile)
        }
        stopRecording()
        return true
    }

    func stopRecording() {
        stopTriggerRecording()
        stopPointRecording()
        isRecordingTrigger = false
        recordingStepId = nil
        message = nil
    }

    private func capturePoint(at axPoint: CGPoint, stepId: UUID) {
        let screenPoint = CoordinateConverter.axScreenPointToAppKit(axPoint)

        guard let frame = WindowLocator.shared.frameContainingPoint(screenPoint, for: profile.bundleIdentifier) else {
            message = "没有在点击位置识别到可读取的 \(profile.appName) 窗口。"
            restoreConfigurationWindow()
            stopPointRecording()
            return
        }

        guard let relativePoint = WindowLocator.shared.relativePoint(from: axPoint, inWindowFrame: frame) else {
            message = "点击位置不在识别到的 \(profile.appName) 窗口范围内。"
            restoreConfigurationWindow()
            stopPointRecording()
            return
        }

        if let idx = steps.firstIndex(where: { $0.id == stepId }) {
            steps[idx].sourceKind = .inline
            steps[idx].inlinePoint = relativePoint
            steps[idx].inlineReferenceSize = frame.size
        }
        message = nil
        restoreConfigurationWindow()
        stopPointRecording()
    }

    private func stopTriggerRecording() {
        triggerRecorder.stop()
    }

    private func stopPointRecording() {
        pointRecorder.stop()
        recordingStepId = nil
    }

    private func restoreConfigurationWindow() {
        NSApp.unhide(nil)
        ConfigurationWindowController.shared.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func activateTargetApplication(retryCount: Int) {
        guard retryCount > 0 else { return }
        guard appResolver.activate(bundleIdentifier: profile.bundleIdentifier) == false else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.activateTargetApplication(retryCount: retryCount - 1)
        }
    }
}
