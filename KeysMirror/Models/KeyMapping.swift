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
    /// 录制该映射时的窗口尺寸；用于在窗口被缩放后按比例换算点击位置。
    /// 旧版本（v1.2 及以下）数据这两个字段为 nil，按固定像素偏移工作。
    var referenceWidth: CGFloat?
    var referenceHeight: CGFloat?

    init(
        id: UUID = UUID(),
        keyCode: UInt16 = 0,
        modifiers: UInt64 = 0,
        triggerType: TriggerType = .keyboard,
        mouseButtonNumber: Int? = nil,
        relativeX: CGFloat,
        relativeY: CGFloat,
        label: String,
        blockInput: Bool = true,
        referenceWidth: CGFloat? = nil,
        referenceHeight: CGFloat? = nil
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
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
    }

    /// 根据当前窗口尺寸换算映射点的窗内偏移。
    /// 若存在参考尺寸，按比例缩放（窗口缩放时点击位置自动跟随）；否则退化为固定像素偏移。
    func absoluteOffset(in windowSize: CGSize) -> CGPoint {
        if let refW = referenceWidth, let refH = referenceHeight, refW > 0, refH > 0 {
            return CGPoint(
                x: relativeX * (windowSize.width / refW),
                y: relativeY * (windowSize.height / refH)
            )
        }
        return CGPoint(x: relativeX, y: relativeY)
    }
}
