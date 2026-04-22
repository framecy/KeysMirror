import CoreGraphics
import Foundation

/// 一条宏：单次触发后按 steps 顺序执行多次点击；可选重复 N 次或无限。
/// 与 KeyMapping 并列存在于同一个 AppProfile 中；触发器空间共享（不允许冲突）。
struct MacroAction: Codable, Identifiable, Hashable {
    let id: UUID
    var label: String
    var triggerType: TriggerType
    var keyCode: UInt16
    var modifiers: UInt64
    var mouseButtonNumber: Int?
    /// 是否拦截原始按键不传给目标 app（与 KeyMapping.blockInput 同义）
    var blockInput: Bool
    var isEnabled: Bool
    /// 1 = 单次；N>1 = N 次；0 = 无限循环（用户再按触发键随时停止）
    var repeatCount: Int
    var steps: [MacroStep]

    init(
        id: UUID = UUID(),
        label: String = "",
        triggerType: TriggerType = .keyboard,
        keyCode: UInt16 = 0,
        modifiers: UInt64 = 0,
        mouseButtonNumber: Int? = nil,
        blockInput: Bool = true,
        isEnabled: Bool = true,
        repeatCount: Int = 1,
        steps: [MacroStep] = []
    ) {
        self.id = id
        self.label = label
        self.triggerType = triggerType
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButtonNumber = mouseButtonNumber
        self.blockInput = blockInput
        self.isEnabled = isEnabled
        self.repeatCount = repeatCount
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.triggerType = try c.decodeIfPresent(TriggerType.self, forKey: .triggerType) ?? .keyboard
        self.keyCode = try c.decodeIfPresent(UInt16.self, forKey: .keyCode) ?? 0
        self.modifiers = try c.decodeIfPresent(UInt64.self, forKey: .modifiers) ?? 0
        self.mouseButtonNumber = try c.decodeIfPresent(Int.self, forKey: .mouseButtonNumber)
        self.blockInput = try c.decodeIfPresent(Bool.self, forKey: .blockInput) ?? true
        self.isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        self.steps = try c.decodeIfPresent([MacroStep].self, forKey: .steps) ?? []
    }

    /// 与 KeyMapping.displayShortcut 同语义：把触发器统一显示为可读字符串。
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

    /// 列表行用的步骤摘要："3 步 × 重复 5 次" / "1 步 × 无限循环"
    var stepSummary: String {
        let repeatText: String
        if repeatCount == 0 {
            repeatText = "无限循环"
        } else if repeatCount == 1 {
            repeatText = "单次"
        } else {
            repeatText = "重复 \(repeatCount) 次"
        }
        return "\(steps.count) 步 × \(repeatText)"
    }
}

struct MacroStep: Codable, Identifiable, Hashable {
    let id: UUID
    /// 本步触发前等待的秒数。第一步通常设为 0 让宏立即开始。
    var delaySeconds: Double
    var position: MacroStepPosition

    init(id: UUID = UUID(), delaySeconds: Double = 0, position: MacroStepPosition) {
        self.id = id
        self.delaySeconds = delaySeconds
        self.position = position
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.delaySeconds = try c.decodeIfPresent(Double.self, forKey: .delaySeconds) ?? 0
        self.position = try c.decode(MacroStepPosition.self, forKey: .position)
    }
}

/// 步骤位置可以引用 profile 内已有 KeyMapping，或自带一份内联坐标（含可选缩放参考）。
/// 自定义 Codable：用 `type` 判别字段 + payload，避免 Swift 默认枚举编码格式难以演进。
enum MacroStepPosition: Hashable {
    case mapping(UUID)
    case inline(relativeX: CGFloat, relativeY: CGFloat, referenceWidth: CGFloat?, referenceHeight: CGFloat?)
}

extension MacroStepPosition: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case mappingId
        case relativeX, relativeY, referenceWidth, referenceHeight
    }

    private enum Kind: String, Codable {
        case mapping
        case inline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .mapping:
            let id = try c.decode(UUID.self, forKey: .mappingId)
            self = .mapping(id)
        case .inline:
            let x = try c.decode(CGFloat.self, forKey: .relativeX)
            let y = try c.decode(CGFloat.self, forKey: .relativeY)
            let refW = try c.decodeIfPresent(CGFloat.self, forKey: .referenceWidth)
            let refH = try c.decodeIfPresent(CGFloat.self, forKey: .referenceHeight)
            self = .inline(relativeX: x, relativeY: y, referenceWidth: refW, referenceHeight: refH)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mapping(let id):
            try c.encode(Kind.mapping, forKey: .type)
            try c.encode(id, forKey: .mappingId)
        case .inline(let x, let y, let refW, let refH):
            try c.encode(Kind.inline, forKey: .type)
            try c.encode(x, forKey: .relativeX)
            try c.encode(y, forKey: .relativeY)
            try c.encodeIfPresent(refW, forKey: .referenceWidth)
            try c.encodeIfPresent(refH, forKey: .referenceHeight)
        }
    }
}
