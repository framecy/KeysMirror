import AppKit
import Combine
import SwiftUI

/// 映射编辑模型。Inspector 用 `autosave: true` 驱动「即时保存」：
/// 任何字段变化后 300ms 内自动落盘；尚未配置完成的草稿不写入，
/// 等触发器 / 位置 / 名称齐备后第一次自动创建（见 docs/UI-Redesign.md 6.3）。
@MainActor
final class MappingEditorViewModel: TriggerEditorViewModel {
    @Published var recordedPoint: CGPoint?
    @Published var recordedReferenceSize: CGSize?
    @Published var blockInput: Bool
    @Published var isRecordingPoint = false

    /// 已持久化的映射；草稿阶段为 nil，第一次成功保存后写入。
    private(set) var existingMapping: KeyMapping?

    private let autosave: Bool
    private var autosaveCancellable: AnyCancellable?
    private var isCommitting = false

    /// 字段撤销：基线 = 上一次已压栈的状态；回写期间置位以免自触发
    private var undoBaseline = EditableMapping()
    private var undoCancellable: AnyCancellable?
    private var isApplyingUndo = false

    /// 触发键录制横跨 will/did 两个覆写点，基线暂存在这里
    private var pendingTriggerUndoBase: EditableMapping?

    init(profile: AppProfile, existingMapping: KeyMapping?, autosave: Bool = false) {
        self.existingMapping = existingMapping
        self.autosave = autosave
        self.blockInput = existingMapping?.blockInput ?? true
        if let existingMapping {
            self.recordedPoint = CGPoint(x: existingMapping.relativeX, y: existingMapping.relativeY)
            if let refW = existingMapping.referenceWidth, let refH = existingMapping.referenceHeight {
                self.recordedReferenceSize = CGSize(width: refW, height: refH)
            }
        }

        super.init(profile: profile)

        // 基类字段的初值必须在 super.init 之后写；也必须在下面接 cancellable 之前写完，
        // 否则初始化本身会被当成一次用户编辑（脏标记 / 撤销基线都会跑偏）。
        self.label = existingMapping?.label ?? ""
        self.recordedKeyCode = existingMapping?.keyCode
        self.recordedModifiers = existingMapping?.modifiers ?? 0
        self.recordedTriggerType = existingMapping?.triggerType ?? .keyboard
        self.recordedMouseButtonNumber = existingMapping?.mouseButtonNumber

        if autosave {
            startAutosave()
            startUndoTracking()
        }
    }

    // MARK: - 基类覆写点

    override func triggerCaptureWillApply() {
        pendingTriggerUndoBase = snapshot
    }

    override func triggerCaptureDidApply() {
        if let before = pendingTriggerUndoBase {
            registerImmediate(name: "录制触发", from: before)
        }
        pendingTriggerUndoBase = nil
    }

    // MARK: - 撤销

    /// 一份可整体存取的编辑态快照。字段撤销以「快照 → 快照」为粒度，
    /// 比逐字段登记简单，也天然支持「录制触发同时自动填了名称」这种一次改多项的情况。
    struct EditableMapping: Equatable {
        var label: String = ""
        var blockInput: Bool = true
        var keyCode: UInt16?
        var modifiers: UInt64 = 0
        var triggerType: TriggerType = .keyboard
        var mouseButtonNumber: Int?
        var point: CGPoint?
        var referenceSize: CGSize?
    }

    private var snapshot: EditableMapping {
        EditableMapping(
            label: label,
            blockInput: blockInput,
            keyCode: recordedKeyCode,
            modifiers: recordedModifiers,
            triggerType: recordedTriggerType,
            mouseButtonNumber: recordedMouseButtonNumber,
            point: recordedPoint,
            referenceSize: recordedReferenceSize
        )
    }

    private func apply(_ s: EditableMapping) {
        isApplyingUndo = true
        label = s.label
        blockInput = s.blockInput
        recordedKeyCode = s.keyCode
        recordedModifiers = s.modifiers
        recordedTriggerType = s.triggerType
        recordedMouseButtonNumber = s.mouseButtonNumber
        recordedPoint = s.point
        recordedReferenceSize = s.referenceSize
        undoBaseline = s
        isApplyingUndo = false
        commit()
    }

    /// 录制这类**离散**操作：立刻把「操作前 → 操作后」压栈（不用等防抖）。
    private func registerImmediate(name: String, from old: EditableMapping) {
        let new = snapshot
        guard new != old else { return }
        undoBaseline = new
        UndoCoordinator.shared.registerPerformed(
            name: name,
            owner: self,
            undo: { [weak self] in self?.apply(old) },
            redo: { [weak self] in self?.apply(new) }
        )
    }

    /// 字段输入（改名、拖动画布上的点…）：停手 600ms 后合并成一条记录，
    /// 否则每敲一个字符就是一条撤销，栈会被淹没。
    private func startUndoTracking() {
        undoBaseline = snapshot
        undoCancellable = objectWillChange
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, !self.isApplyingUndo, !self.isRecordingTrigger, !self.isRecordingPoint else { return }
                let old = self.undoBaseline
                let new = self.snapshot
                guard new != old else { return }
                self.undoBaseline = new
                UndoCoordinator.shared.registerPerformed(
                    name: "编辑映射",
                    owner: self,
                    undo: { [weak self] in self?.apply(old) },
                    redo: { [weak self] in self?.apply(new) }
                )
            }
    }

    /// Inspector 关闭时调用：不要在栈里留下指向已消失编辑器的记录
    func discardUndoHistory() {
        UndoCoordinator.shared.removeActions(for: self)
    }

    // MARK: - 派生状态

    var isDraft: Bool { existingMapping == nil }

    var pointText: String {
        guard let recordedPoint else { return "未录制" }
        return "x: \(Int(recordedPoint.x)), y: \(Int(recordedPoint.y))"
    }

    var canSave: Bool {
        hasTrigger && recordedPoint != nil && !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 草稿还缺什么，用于 Inspector 顶部提示
    var draftHint: String? {
        guard isDraft else { return nil }
        var missing: [String] = []
        if !hasTrigger { missing.append("触发键") }
        if recordedPoint == nil { missing.append("点击位置") }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("名称") }
        guard !missing.isEmpty else { return nil }
        return "草稿 · 还需要：\(missing.joined(separator: "、"))"
    }

    // MARK: - 录制

    func startPointRecording() {
        stopPointRecording()

        guard let targetApp = appResolver.runningApplication(bundleIdentifier: profile.bundleIdentifier) else {
            setMessage("\(profile.appName) 当前没有运行。")
            return
        }

        isRecordingPoint = true
        setMessage("正在激活 \(profile.appName)，请在目标窗口中点击一次。")

        let started = pointRecorder.start { [weak self] point in
            self?.capturePoint(at: point)
        }
        guard started else {
            isRecordingPoint = false
            setMessage("无法启动点击录制，请确认已经授予辅助功能权限。")
            return
        }

        RecordingSession.shared.begin(
            profile: profile,
            title: "录制点击位置 · \(profile.appName)",
            subtitle: "在窗口中点击一次 · Esc 取消",
            targetApp: targetApp
        )
    }

    func stopRecording() {
        stopTriggerRecording()
        stopPointRecording()
        isRecordingTrigger = false
        isRecordingPoint = false
        setMessage(nil)
    }

    // MARK: - 保存

    /// 落盘。草稿未配置完成时静默跳过；触发器冲突时给出指名道姓的提示并放弃本次写入。
    @discardableResult
    func commit() -> Bool {
        guard canSave, let recordedPoint else { return false }

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

        if let owner = MappingStore.shared.triggerOwner(
            triggerType: mapping.triggerType,
            keyCode: mapping.keyCode,
            modifiers: mapping.modifiers,
            mouseButtonNumber: mapping.mouseButtonNumber,
            in: profile,
            excludingMappingId: mapping.id
        ) {
            setMessage("\(shortcutText) 已被\(owner.kindText)「\(owner.label)」占用")
            return false
        }

        if existingMapping == nil {
            MappingStore.shared.addMapping(mapping, to: profile)
        } else {
            MappingStore.shared.updateMapping(mapping, in: profile)
        }
        existingMapping = mapping
        setMessage(nil)
        return true
    }

    // MARK: - Internal

    private func capturePoint(at axPoint: CGPoint) {
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

        let before = snapshot
        recordedPoint = relativePoint
        // 记下录制时的窗口尺寸，后续按比例换算点击坐标，支持窗口缩放跟随
        recordedReferenceSize = frame.size
        setMessage(nil)
        flashCaptured()
        registerImmediate(name: "录制位置", from: before)
        RecordingSession.shared.end()
        stopPointRecording()
    }

    /// 更新画布拖动后的坐标（不改参考尺寸）
    func updatePoint(_ point: CGPoint) {
        recordedPoint = point
    }

    private func stopPointRecording() {
        pointRecorder.stop()
        isRecordingPoint = false
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
