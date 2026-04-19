import AppKit
import SwiftUI

struct MappingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: MappingEditorViewModel

    init(profile: AppProfile, existingMapping: KeyMapping?) {
        _viewModel = StateObject(wrappedValue: MappingEditorViewModel(profile: profile, existingMapping: existingMapping))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(viewModel.existingMapping == nil ? "新建映射" : "编辑映射")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("关闭") {
                    viewModel.stopRecording()
                    dismiss()
                }
            }

            TextField("标签名称", text: $viewModel.label)
                .textFieldStyle(.roundedBorder)

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
                Text("点击“录制触发”后，按下键盘快捷键，或点击鼠标右键、侧键。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("拦截原始按键（推荐）", isOn: $viewModel.blockInput)
                    .toggleStyle(.switch)
                    .help("关闭后按键会同时触发点击并传递给目标应用，适用于需要在游戏聊天框等场景同时打字的情况")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("点击位置")
                    .font(.headline)
                Text(viewModel.pointText)
                    .font(.system(.body, design: .monospaced))
                Text("点击“录制位置”后，程序会自动切到目标应用，请在目标窗口中点击一次。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(viewModel.isRecordingPoint ? "等待点击..." : "录制位置") {
                        viewModel.startPointRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }

            if let message = viewModel.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Button("取消") {
                    viewModel.stopRecording()
                    dismiss()
                }
                Spacer()
                Button(viewModel.existingMapping == nil ? "保存映射" : "更新映射") {
                    viewModel.save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSave)
            }
        }
        .padding(20)
        .frame(width: 520, height: 400)
        .background {
            Color(nsColor: .windowBackgroundColor)
        }
    }
}

@MainActor
final class MappingEditorViewModel: ObservableObject {
    @Published var label: String
    @Published var recordedKeyCode: UInt16?
    @Published var recordedModifiers: UInt64
    @Published var recordedTriggerType: TriggerType
    @Published var recordedMouseButtonNumber: Int?
    @Published var recordedPoint: CGPoint?
    @Published var recordedReferenceSize: CGSize?
    @Published var blockInput: Bool
    @Published var isRecordingTrigger = false
    @Published var isRecordingPoint = false
    @Published var message: String?

    let profile: AppProfile
    let existingMapping: KeyMapping?

    private let appResolver = AppResolver.shared
    private let pointRecorder = PointRecorder.shared
    private let triggerRecorder = TriggerRecorder.shared

    init(profile: AppProfile, existingMapping: KeyMapping?) {
        self.profile = profile
        self.existingMapping = existingMapping
        self.label = existingMapping?.label ?? ""
        self.recordedKeyCode = existingMapping?.keyCode
        self.recordedModifiers = existingMapping?.modifiers ?? 0
        self.recordedTriggerType = existingMapping?.triggerType ?? .keyboard
        self.recordedMouseButtonNumber = existingMapping?.mouseButtonNumber
        self.blockInput = existingMapping?.blockInput ?? true
        if let existingMapping {
            self.recordedPoint = CGPoint(x: existingMapping.relativeX, y: existingMapping.relativeY)
            if let refW = existingMapping.referenceWidth, let refH = existingMapping.referenceHeight {
                self.recordedReferenceSize = CGSize(width: refW, height: refH)
            }
        }
    }

    var shortcutText: String {
        switch recordedTriggerType {
        case .keyboard:
            guard let recordedKeyCode else { return "未录制" }
            return CGKeyCodeNames.shortcutLabel(for: recordedKeyCode, modifiers: recordedModifiers)
        case .mouseRight:
            return "鼠标右键"
        case .mouseOther:
            if let num = recordedMouseButtonNumber {
                return "鼠标按键 \(num)"
            }
            return "鼠标多功能键"
        }
    }

    var pointText: String {
        guard let recordedPoint else { return "未录制" }
        return "x: \(Int(recordedPoint.x)), y: \(Int(recordedPoint.y))"
    }

    var canSave: Bool {
        let hasTrigger: Bool
        switch recordedTriggerType {
        case .keyboard:
            hasTrigger = recordedKeyCode != nil
        case .mouseRight:
            hasTrigger = true
        case .mouseOther:
            hasTrigger = recordedMouseButtonNumber != nil
        }
        
        return hasTrigger && recordedPoint != nil && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                self.label = self.label.isEmpty ? CGKeyCodeNames.name(for: keyCode) : self.label
            case .mouseRight:
                self.recordedTriggerType = .mouseRight
                self.recordedKeyCode = 0
                self.recordedModifiers = 0
                self.recordedMouseButtonNumber = nil
                self.label = self.label.isEmpty ? "鼠标右键" : self.label
            case .mouseOther(let buttonNumber):
                self.recordedTriggerType = .mouseOther
                self.recordedMouseButtonNumber = buttonNumber
                self.recordedKeyCode = 0
                self.recordedModifiers = 0
                self.label = self.label.isEmpty ? "鼠标按键 \(buttonNumber)" : self.label
            }
            
            self.isRecordingTrigger = false
            self.message = nil
        }
    }

    func startPointRecording() {
        stopPointRecording()

        guard let targetApp = appResolver.runningApplication(bundleIdentifier: profile.bundleIdentifier) else {
            message = "\(profile.appName) 当前没有运行。"
            return
        }

        isRecordingPoint = true
        message = "正在激活 \(profile.appName)，请在目标窗口中点击一次。"

        let started = pointRecorder.start { [weak self] point in
            guard let self else { return }
            self.capturePoint(at: point)
        }
        guard started else {
            isRecordingPoint = false
            message = "无法启动点击录制，请确认已经授予辅助功能权限。"
            return
        }

        // 仅隐藏配置窗口（含其上承载的本 Sheet），其他面板/状态项不动。
        ConfigurationWindowController.shared.hide()
        NSApp.deactivate()
        targetApp.unhide()
        activateTargetApplication(retryCount: 3)
    }

    func save() {
        guard let recordedPoint else { return }

        let mapping = KeyMapping(
            id: existingMapping?.id ?? UUID(),
            keyCode: recordedKeyCode ?? 0,
            modifiers: recordedModifiers,
            triggerType: recordedTriggerType,
            mouseButtonNumber: recordedMouseButtonNumber,
            relativeX: recordedPoint.x,
            relativeY: recordedPoint.y,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            blockInput: blockInput,
            referenceWidth: recordedReferenceSize?.width ?? existingMapping?.referenceWidth,
            referenceHeight: recordedReferenceSize?.height ?? existingMapping?.referenceHeight,
            isEnabled: existingMapping?.isEnabled ?? true
        )

        // 触发器去重检查（同 profile 内同一 trigger 不允许两条映射）
        if MappingStore.shared.hasDuplicateTrigger(mapping, in: profile, excludingId: existingMapping?.id) {
            message = "已存在相同触发的映射，请更换按键或编辑已有映射。"
            return
        }

        if existingMapping == nil {
            MappingStore.shared.addMapping(mapping, to: profile)
        } else {
            MappingStore.shared.updateMapping(mapping, in: profile)
        }

        stopRecording()
    }

    func stopRecording() {
        stopTriggerRecording()
        stopPointRecording()
        isRecordingTrigger = false
        isRecordingPoint = false
        message = nil
    }

    private func capturePoint(at axPoint: CGPoint) {
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

        recordedPoint = relativePoint
        // 记下录制时的窗口尺寸，后续按比例换算点击坐标，支持窗口缩放跟随
        recordedReferenceSize = frame.size
        message = nil
        restoreConfigurationWindow()
        stopPointRecording()
    }

    private func stopTriggerRecording() {
        triggerRecorder.stop()
    }

    private func stopPointRecording() {
        pointRecorder.stop()
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
