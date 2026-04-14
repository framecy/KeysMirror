import CoreGraphics
import Foundation

enum TriggerType: String, Codable, CaseIterable {
    case keyboard
    case mouseRight
    case mouseOther
}

struct KeyMapping: Codable, Identifiable, Hashable {
    let id: UUID
    var keyCode: UInt16
    var modifiers: UInt64
    var triggerType: TriggerType
    var mouseButtonNumber: Int?
    var relativeX: CGFloat
    var relativeY: CGFloat
    var label: String
    var blockInput: Bool
    // 允许同一键位用于不同修饰键组合
    // 防止重复映射在 Model 层检查

    init(
        id: UUID = UUID(),
        keyCode: UInt16 = 0,
        modifiers: UInt64 = 0,
        triggerType: TriggerType = .keyboard,
        mouseButtonNumber: Int? = nil,
        relativeX: CGFloat,
        relativeY: CGFloat,
        label: String,
        blockInput: Bool = true
    ) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.triggerType = triggerType
        self.mouseButtonNumber = mouseButtonNumber
        self.relativeX = relativeX
        self.relativeY = relativeY
        self.label = label
        self.blockInput = blockInput
    }
}