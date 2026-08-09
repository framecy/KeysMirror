import AppKit
import Combine
import SwiftUI

/// 两个 Inspector 编辑模型（映射 / 宏）的公共底座：触发键录制 + 捕获反馈 + 提示消息。
///
/// 抽出来之前 `MappingEditorViewModel` 和 `MacroEditorViewModel` 各写了一份：
/// `capTrigger` / `hasTrigger` / `flashCaptured` / `setMessage` / `stopTriggerRecording`
/// 逐字节相同，`shortcutText` 只差换行，`startTriggerRecording` 只差两点——
/// 自动命名的前缀（宏是「宏 xxx」），以及映射那边多一次撤销登记。
/// 这两点分别由 `autoLabelPrefix` 和 `triggerCaptureWillApply/DidApply` 两个覆写点吸收。
///
/// 用基类而不是 protocol extension：这些状态是**存储属性**（`@Published`），
/// protocol 只能要求它们存在、没法提供，抽出来的还是壳子。
@MainActor
class TriggerEditorViewModel: ObservableObject {
    @Published var label: String = ""
    @Published var recordedKeyCode: UInt16?
    @Published var recordedModifiers: UInt64 = 0
    @Published var recordedTriggerType: TriggerType = .keyboard
    @Published var recordedMouseButtonNumber: Int?
    @Published var isRecordingTrigger = false
    @Published var justCaptured = false
    @Published var message: String?

    let profile: AppProfile

    let appResolver = AppResolver.shared
    let pointRecorder = PointRecorder.shared
    let triggerRecorder = TriggerRecorder.shared

    init(profile: AppProfile) {
        self.profile = profile
    }

    // MARK: - 子类覆写点

    /// 录到触发键且名称还空着时自动填名，这是前缀。宏编辑器用 `"宏 "`，映射为空。
    var autoLabelPrefix: String { "" }

    /// 触发键写入模型**之前**调用。子类在这里存一份撤销基线。
    func triggerCaptureWillApply() {}

    /// 触发键写入完毕、反馈也放完之后调用。子类在这里压撤销栈。
    func triggerCaptureDidApply() {}

    // MARK: - 派生状态

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

    // MARK: - 触发键录制

    func startTriggerRecording() {
        stopTriggerRecording()
        isRecordingTrigger = true
        setMessage("按下键盘按键，或点击鼠标右键、多功能键。")

        _ = triggerRecorder.start { [weak self] trigger in
            guard let self else { return }
            self.triggerCaptureWillApply()
            switch trigger {
            case .keyboard(let keyCode, let modifiers):
                self.recordedTriggerType = .keyboard
                self.recordedKeyCode = keyCode
                self.recordedModifiers = modifiers
                self.recordedMouseButtonNumber = nil
                if self.label.isEmpty {
                    self.label = self.autoLabelPrefix + CGKeyCodeNames.name(for: keyCode)
                }
            case .mouseRight:
                self.recordedTriggerType = .mouseRight
                self.recordedKeyCode = 0
                self.recordedModifiers = 0
                self.recordedMouseButtonNumber = nil
                if self.label.isEmpty { self.label = self.autoLabelPrefix + "鼠标右键" }
            case .mouseOther(let buttonNumber):
                self.recordedTriggerType = .mouseOther
                self.recordedMouseButtonNumber = buttonNumber
                self.recordedKeyCode = 0
                self.recordedModifiers = 0
                if self.label.isEmpty { self.label = self.autoLabelPrefix + "鼠标按键 \(buttonNumber)" }
            }
            self.isRecordingTrigger = false
            self.setMessage(nil)
            self.flashCaptured()
            self.triggerCaptureDidApply()
        }
    }

    func stopTriggerRecording() {
        triggerRecorder.stop()
    }

    // MARK: - 反馈

    /// 录到东西后短暂点亮「已捕获」态，900ms 后自动熄灭。
    func flashCaptured() {
        justCaptured = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.justCaptured = false
        }
    }

    /// 只在值真的变化时赋值：避免 autosave 的 objectWillChange 自激循环。
    func setMessage(_ new: String?) {
        if message != new { message = new }
    }
}
