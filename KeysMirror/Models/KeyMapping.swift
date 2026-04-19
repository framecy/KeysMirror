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
    /// 单条映射启用开关；用户可在列表中临时关闭某条不删除。
    /// 旧数据缺字段时按 true 解码（向后兼容）。
    var isEnabled: Bool

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
        referenceHeight: CGFloat? = nil,
        isEnabled: Bool = true
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
        self.isEnabled = isEnabled
    }

    /// 自定义 Decodable：让旧版本 mappings.json 在缺少新字段时仍能解析（向后兼容）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0
        self.modifiers = try c.decodeIfPresent(UInt64.self, forKey: .modifiers) ?? 0
        self.triggerType = try c.decodeIfPresent(TriggerType.self, forKey: .triggerType) ?? .keyboard
        self.mouseButtonNumber = try c.decodeIfPresent(Int.self, forKey: .mouseButtonNumber)
        self.relativeX = try c.decode(CGFloat.self, forKey: .relativeX)
        self.relativeY = try c.decode(CGFloat.self, forKey: .relativeY)
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.blockInput = try c.decodeIfPresent(Bool.self, forKey: .blockInput) ?? true
        self.referenceWidth = try c.decodeIfPresent(CGFloat.self, forKey: .referenceWidth)
        self.referenceHeight = try c.decodeIfPresent(CGFloat.self, forKey: .referenceHeight)
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
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

    /// 按 triggerType 统一展示触发方式（键盘快捷键、鼠标右键、鼠标侧键编号）。
    /// MappingListView 直接读取，避免对鼠标触发器显示无意义的 keyCode。
    var displayShortcut: String {
        switch triggerType {
        case .keyboard:
            return CGKeyCodeNames.shortcutLabel(for: keyCode, modifiers: modifiers)
        case .mouseRight:
            return "鼠标右键"
        case .mouseOther:
            if let num = mouseButtonNumber {
                return "鼠标按键 \(num)"
            }
            return "鼠标侧键"
        }
    }

    /// 是否带有窗口尺寸参考；列表 UI 据此显示"缩放跟随"徽标。
    var hasScaleReference: Bool {
        guard let w = referenceWidth, let h = referenceHeight else { return false }
        return w > 0 && h > 0
    }
}
