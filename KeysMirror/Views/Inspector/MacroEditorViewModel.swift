import AppKit
import Combine
import SwiftUI

// MARK: - 可编辑步骤（UI 侧结构，不直接持久化）

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
    var driftPercent: Double
    var clickCount: Int
    /// UI 折叠态：默认收起，只显示摘要行
    var isExpanded: Bool = false

    init(id: UUID = UUID(), step: MacroStep? = nil) {
        self.id = step?.id ?? id
        self.driftPercent = step?.driftPercent ?? 0
        self.clickCount = max(1, step?.clickCount ?? 1)
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
            self.sourceKind = .inline
            self.referencedMappingId = nil
        }
    }

    var delaySecondsValue: Double {
        delayUnit == .seconds ? delayValue : delayValue * 60
    }

    /// 折叠态摘要：「延迟 1.2s → (412,880) ×2 · 漂移 1%」
    var summary: String {
        var parts: [String] = []
        if delaySecondsValue > 0 {
            parts.append("延迟 \(formatted(delaySecondsValue))s")
        } else {
            parts.append("立即")
        }
        switch sourceKind {
        case .inline:
            if let p = inlinePoint {
                parts.append("(\(Int(p.x)), \(Int(p.y)))")
            } else {
                parts.append("未录制")
            }
        case .mapping:
            parts.append(referencedMappingId == nil ? "未选择映射" : "引用映射")
        }
        if clickCount > 1 { parts.append("×\(clickCount)") }
        if driftPercent > 0 { parts.append("漂移 \(formatted(driftPercent))%") }
        return parts.joined(separator: " · ")
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
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
        return MacroStep(
            id: id,
            delaySeconds: max(0, delaySecondsValue),
            position: pos,
            driftPercent: min(max(0, driftPercent), 50),
            clickCount: min(max(1, clickCount), 20)
        )
    }
}

// MARK: - View Model

/// 宏编辑模型。Inspector 用 `autosave: true` 即时保存（见 MappingEditorViewModel 的同名机制）。
@MainActor
final class MacroEditorViewModel: ObservableObject {
    @Published var label: String
    @Published var blockInput: Bool
    /// 重复模式**显式存储**。
    /// 早先是从 `repeatCountText` 反推（<=1 就算「单次」），于是输入框里敲个 1
    /// 分段控件就自己跳到「单次」，输入 10 的中间态还会来回闪——典型的派生状态回环。
    @Published var repeatMode: RepeatMode
    @Published var repeatCountText: Int

    enum RepeatMode: String, Hashable, CaseIterable {
        case once, count, infinite
    }

    @Published var steps: [EditableStep]
    @Published var recordedKeyCode: UInt16?
    @Published var recordedModifiers: UInt64
    @Published var recordedTriggerType: TriggerType
    @Published var recordedMouseButtonNumber: Int?
    @Published var isRecordingTrigger = false
    @Published var recordingStepId: UUID?
    @Published var isRecordingSequence = false
    @Published var recordedClickCount = 0
    @Published var justCaptured = false
    @Published var message: String?

    let profile: AppProfile
    private(set) var existingMacro: MacroAction?

    /// 草稿第一次成功保存、拿到真实 id 时触发一次。
    /// 供 `MacroEditorWindowController` 把窗口从临时的 draft key 重绑到 macro id，
    /// 否则「新建→自动保存→从列表点编辑同一条宏」会在草稿窗口之外再开一个窗口，
    /// 两个 view model 各自即时保存、互相覆盖对方的改动。
    var onFirstCommit: ((MacroAction) -> Void)?

    /// 序列录制期间累积的点击样本（已换算成窗口内相对坐标）
    private var sequenceSamples: [SequenceSample] = []

    private let autosave: Bool
    private var autosaveCancellable: AnyCancellable?
    private var dirtyCancellable: AnyCancellable?

    /// 有未保存的改动（仅非 autosave 模式下有意义）。
    /// 编辑器改成显式保存后，用它驱动「保存」按钮的可用态与未保存提示。
    @Published private(set) var hasUnsavedChanges = false
    private var isCommitting = false

    /// 步骤撤销：基线 = 上一次已压栈的状态；回写期间置位以免自触发
    private var stepsBaseline: [EditableStep] = []
    private var stepsUndoCancellable: AnyCancellable?
    private var isApplyingStepsUndo = false

    private let appResolver = AppResolver.shared
    private let pointRecorder = PointRecorder.shared
    private let triggerRecorder = TriggerRecorder.shared
    private let sequenceRecorder = MacroSequenceRecorder.shared

    init(profile: AppProfile, existingMacro: MacroAction?, autosave: Bool = false) {
        self.profile = profile
        self.existingMacro = existingMacro
        self.autosave = autosave
        self.label = existingMacro?.label ?? ""
        self.blockInput = existingMacro?.blockInput ?? true
        let count = existingMacro?.repeatCount ?? 1
        if count == 0 {
            self.repeatMode = .infinite
            self.repeatCountText = 10
        } else if count == 1 {
            self.repeatMode = .once
            self.repeatCountText = 10
        } else {
            self.repeatMode = .count
            self.repeatCountText = count
        }
        self.steps = (existingMacro?.steps ?? []).map { EditableStep(step: $0) }
        self.recordedKeyCode = existingMacro?.keyCode
        self.recordedModifiers = existingMacro?.modifiers ?? 0
        self.recordedTriggerType = existingMacro?.triggerType ?? .keyboard
        self.recordedMouseButtonNumber = existingMacro?.mouseButtonNumber
        if !autosave {
            // 非 autosave：任何改动都标脏。判空再置位，否则会和 objectWillChange 互相触发成死循环。
            dirtyCancellable = objectWillChange
                .sink { [weak self] in
                    guard let self, !self.hasUnsavedChanges, !self.isCommitting else { return }
                    Task { @MainActor in self.hasUnsavedChanges = true }
                }
        }
        if autosave {
            startAutosave()
            startStepsUndoTracking()
        }
    }

    // MARK: - 派生状态

    var isDraft: Bool { existingMacro == nil }

    var shortcutText: String {
        switch recordedTriggerType {
        case .keyboard:
            guard let recordedKeyCode else { return "未录制" }
            return CGKeyCodeNames.shortcutLabel(for: recordedKeyCode, modifiers: recordedModifiers)
        case .mouseRight: return "鼠标右键"
        case .mouseOther:
            if let num = recordedMouseButtonNumber { return "鼠标按键 \(num)" }
            return "鼠标多功能键"
        }
    }

    var capTrigger: KeyCapView.Trigger {
        switch recordedTriggerType {
        case .keyboard:
            guard let recordedKeyCode else { return .none }
            return .keyboard(keyCode: recordedKeyCode, modifiers: recordedModifiers)
        case .mouseRight: return .mouseRight
        case .mouseOther: return .mouseOther(buttonNumber: recordedMouseButtonNumber)
        }
    }

    var hasTrigger: Bool {
        switch recordedTriggerType {
        case .keyboard: return recordedKeyCode != nil
        case .mouseRight: return true
        case .mouseOther: return recordedMouseButtonNumber != nil
        }
    }

    var canSave: Bool {
        let allStepsValid = !steps.isEmpty && steps.allSatisfy { $0.toMacroStep() != nil }
        return hasTrigger && allStepsValid && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var draftHint: String? {
        guard isDraft else { return nil }
        var missing: [String] = []
        if !hasTrigger { missing.append("触发键") }
        if steps.isEmpty { missing.append("至少一个步骤") }
        else if steps.contains(where: { $0.toMacroStep() == nil }) { missing.append("补全未配置的步骤") }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("名称") }
        guard !missing.isEmpty else { return nil }
        return "草稿 · 还需要：\(missing.joined(separator: "、"))"
    }

    // MARK: - 步骤操作（全部可撤销）

    func addStep() {
        mutateSteps("新增步骤") { steps in
            var step = EditableStep()
            step.isExpanded = true
            steps.append(step)
        }
    }

    func removeStep(at index: Int) {
        guard steps.indices.contains(index) else { return }
        mutateSteps("删除步骤") { $0.remove(at: index) }
    }

    func moveStep(from: Int, to: Int) {
        guard steps.indices.contains(from), to >= 0, to < steps.count else { return }
        mutateSteps("移动步骤") { steps in
            let item = steps.remove(at: from)
            steps.insert(item, at: to)
        }
    }

    /// SwiftUI `.onMove` 用（拖拽排序）
    func moveSteps(fromOffsets: IndexSet, toOffset: Int) {
        mutateSteps("排序步骤") { $0.move(fromOffsets: fromOffsets, toOffset: toOffset) }
    }

    func duplicateStep(at index: Int) {
        guard steps.indices.contains(index) else { return }
        mutateSteps("复制步骤") { steps in
            let source = steps[index]
            let copy = EditableStep(id: UUID(), step: source.toMacroStep().map {
                MacroStep(id: UUID(), delaySeconds: $0.delaySeconds, position: $0.position, driftPercent: $0.driftPercent, clickCount: $0.clickCount)
            })
            steps.insert(copy, at: index + 1)
        }
    }

    // MARK: - 步骤撤销

    /// 结构性改动（增删改序 / 录制结果）：整段数组前后对比压栈。
    /// 字段级输入不走这里，由下面的防抖合并成一条记录，避免每敲一个字符一条撤销。
    private func mutateSteps(_ name: String, _ transform: (inout [EditableStep]) -> Void) {
        let old = steps
        var updated = steps
        transform(&updated)
        guard updated != old else { return }

        UndoCoordinator.shared.perform(
            name: name,
            owner: self,
            do: { [weak self] in self?.setSteps(updated) },
            undo: { [weak self] in self?.setSteps(old) }
        )
    }

    /// 撤销 / 重做时回写；同时同步基线，避免防抖watcher把这次回写又当成一次新编辑。
    private func setSteps(_ value: [EditableStep]) {
        isApplyingStepsUndo = true
        steps = value
        stepsBaseline = value
        isApplyingStepsUndo = false
    }

    /// 字段级编辑：停手 600ms 后把整段「编辑前 → 编辑后」合并成一条撤销记录。
    private func startStepsUndoTracking() {
        stepsBaseline = steps
        stepsUndoCancellable = $steps
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] newValue in
                guard let self, !self.isApplyingStepsUndo else { return }
                let old = self.stepsBaseline
                guard newValue != old else { return }
                self.stepsBaseline = newValue
                UndoCoordinator.shared.registerPerformed(
                    name: "编辑步骤",
                    owner: self,
                    undo: { [weak self] in self?.setSteps(old) },
                    redo: { [weak self] in self?.setSteps(newValue) }
                )
            }
    }

    /// Inspector 关闭时调用：撤销栈里不该留下指向已消失编辑器的记录
    func discardStepUndoHistory() {
        UndoCoordinator.shared.removeActions(for: self)
    }

    // MARK: - 录制

    func startTriggerRecording() {
        stopTriggerRecording()
        isRecordingTrigger = true
        setMessage("按下键盘按键，或点击鼠标右键、多功能键。")

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
            self.setMessage(nil)
            self.flashCaptured()
        }
    }

    func startPointRecording(forStepId stepId: UUID) {
        stopPointRecording()

        guard let targetApp = appResolver.runningApplication(bundleIdentifier: profile.bundleIdentifier) else {
            setMessage("\(profile.appName) 当前没有运行。")
            return
        }

        recordingStepId = stepId
        setMessage("正在激活 \(profile.appName)，请在目标窗口中点击一次。")

        let started = pointRecorder.start { [weak self] point in
            self?.capturePoint(at: point, stepId: stepId)
        }
        guard started else {
            recordingStepId = nil
            setMessage("无法启动点击录制，请确认已经授予辅助功能权限。")
            return
        }

        RecordingSession.shared.begin(
            profile: profile,
            title: "录制步骤位置 · \(profile.appName)",
            subtitle: "在窗口中点击一次 · Esc 取消",
            targetApp: targetApp
        )
    }

    // MARK: - 序列录制

    func toggleSequenceRecording() {
        if isRecordingSequence {
            finishSequenceRecording()
        } else {
            startSequenceRecording()
        }
    }

    func startSequenceRecording() {
        stopRecording()

        guard let targetApp = appResolver.runningApplication(bundleIdentifier: profile.bundleIdentifier) else {
            setMessage("\(profile.appName) 当前没有运行。")
            return
        }

        sequenceSamples.removeAll()
        recordedClickCount = 0

        let started = sequenceRecorder.start(
            onClick: { [weak self] click in self?.captureSequenceClick(click) },
            onFinish: { [weak self] in self?.finishSequenceRecording() }
        )
        guard started else {
            setMessage("无法启动录制，请确认已经授予辅助功能权限。")
            return
        }

        isRecordingSequence = true
        setMessage("正在录制点击序列：在 \(profile.appName) 窗口里操作，按 Esc 结束。")

        RecordingSession.shared.begin(
            profile: profile,
            title: "正在录制宏 · \(profile.appName)",
            subtitle: "点击会记录位置、间隔与连击 · Esc 结束",
            targetApp: targetApp,
            showsClickCount: true
        )
    }

    /// 结束录制并把样本转成步骤追加到现有步骤后面。
    func finishSequenceRecording() {
        guard isRecordingSequence else { return }
        sequenceRecorder.stop()
        isRecordingSequence = false

        let newSteps = MacroSequenceRecorder.buildSteps(from: sequenceSamples)
        sequenceSamples.removeAll()

        if newSteps.isEmpty {
            setMessage("没有录到落在 \(profile.appName) 窗口内的点击。")
        } else {
            let recorded = newSteps.map { EditableStep(step: $0) }
            mutateSteps("录制步骤") { $0.append(contentsOf: recorded) }
            let clicks = newSteps.reduce(0) { $0 + $1.clickCount }
            setMessage("已录制 \(newSteps.count) 个步骤（共 \(clicks) 次点击）。")
            if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                label = "录制宏"
            }
        }

        RecordingSession.shared.end()
    }

    private func captureSequenceClick(_ click: RecordedClick) {
        // 点在目标窗口外（切了其他 app、点到桌面）→ 忽略这一次，录制继续
        guard let frame = WindowLocator.shared.frameContainingPoint(
            CoordinateConverter.axScreenPointToAppKit(click.location),
            for: profile.bundleIdentifier
        ),
        let relativePoint = WindowLocator.shared.relativePoint(from: click.location, inWindowFrame: frame) else {
            RecordingSession.shared.rejectOutOfBounds(appName: profile.appName)
            return
        }

        sequenceSamples.append(
            SequenceSample(
                relativePoint: relativePoint,
                referenceSize: frame.size,
                elapsed: click.elapsed,
                clickState: click.clickState
            )
        )
        recordedClickCount = sequenceSamples.count
        RecordingSession.shared.updateClickCount(recordedClickCount)
    }

    /// 模式 + 次数 → 持久化的 repeatCount（0 = 无限，1 = 单次，N = N 次）。纯函数，可单测。
    static func repeatCount(mode: RepeatMode, count: Int) -> Int {
        switch mode {
        case .infinite: return 0
        case .once: return 1
        case .count: return max(2, count)
        }
    }

    // MARK: - 保存

    @discardableResult
    func commit() -> Bool {
        guard canSave else { return false }
        let wasDraft = existingMacro == nil

        let macroSteps = steps.compactMap { $0.toMacroStep() }
        guard macroSteps.count == steps.count else {
            setMessage("存在尚未配置完成的步骤")
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
            repeatCount: Self.repeatCount(mode: repeatMode, count: repeatCountText),
            steps: macroSteps
        )

        if let owner = MappingStore.shared.triggerOwner(
            triggerType: macro.triggerType,
            keyCode: macro.keyCode,
            modifiers: macro.modifiers,
            mouseButtonNumber: macro.mouseButtonNumber,
            in: profile,
            excludingMacroId: macro.id
        ) {
            setMessage("\(shortcutText) 已被\(owner.kindText)「\(owner.label)」占用")
            return false
        }

        if existingMacro == nil {
            MappingStore.shared.addMacro(macro, to: profile)
        } else {
            MappingStore.shared.updateMacro(macro, in: profile)
        }
        existingMacro = macro
        setMessage(nil)
        hasUnsavedChanges = false
        if wasDraft { onFirstCommit?(macro) }
        return true
    }

    func stopRecording() {
        stopTriggerRecording()
        stopPointRecording()
        if isRecordingSequence {
            sequenceRecorder.stop()
            sequenceSamples.removeAll()
            isRecordingSequence = false
            recordedClickCount = 0
            RecordingSession.shared.end()
        }
        isRecordingTrigger = false
        recordingStepId = nil
        setMessage(nil)
    }

    // MARK: - Internal

    private func capturePoint(at axPoint: CGPoint, stepId: UUID) {
        let screenPoint = CoordinateConverter.axScreenPointToAppKit(axPoint)

        guard let frame = WindowLocator.shared.frameContainingPoint(screenPoint, for: profile.bundleIdentifier) else {
            setMessage("没有在点击位置识别到可读取的 \(profile.appName) 窗口。")
            RecordingSession.shared.end()
            stopPointRecording()
            return
        }

        guard let relativePoint = WindowLocator.shared.relativePoint(from: axPoint, inWindowFrame: frame) else {
            setMessage("点击位置不在识别到的 \(profile.appName) 窗口范围内。")
            RecordingSession.shared.end()
            stopPointRecording()
            return
        }

        mutateSteps("录制步骤位置") { steps in
            guard let idx = steps.firstIndex(where: { $0.id == stepId }) else { return }
            steps[idx].sourceKind = .inline
            steps[idx].inlinePoint = relativePoint
            steps[idx].inlineReferenceSize = frame.size
        }
        setMessage(nil)
        flashCaptured()
        RecordingSession.shared.end()
        stopPointRecording()
    }

    private func flashCaptured() {
        justCaptured = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.justCaptured = false
        }
    }

    private func stopTriggerRecording() {
        triggerRecorder.stop()
    }

    private func stopPointRecording() {
        pointRecorder.stop()
        recordingStepId = nil
    }

    private func setMessage(_ new: String?) {
        if message != new { message = new }
    }

    private func startAutosave() {
        autosaveCancellable = objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, !self.isCommitting else { return }
                self.isCommitting = true
                self.commit()
                self.isCommitting = false
            }
    }
}
