import Foundation

/// 触发器占用信息：谁占了这个键。
/// 映射与宏是两个独立列表（不合并），但共享同一触发器空间——
/// 「这个键被谁占了」由这里的只读投影回答（键位总览 / 冲突提示）。
struct TriggerOccupancy: Hashable, Identifiable {
    enum Kind: String, Hashable {
        case mapping
        case macro

        var text: String {
            switch self {
            case .mapping: return "映射"
            case .macro: return "宏"
            }
        }
    }

    var id: UUID { ownerId }
    let kind: Kind
    let ownerId: UUID
    let label: String
    let triggerType: TriggerType
    let keyCode: UInt16
    let modifiers: UInt64
    let mouseButtonNumber: Int?
    let isEnabled: Bool

    var kindText: String { kind.text }

    var displayShortcut: String {
        switch triggerType {
        case .keyboard: return CGKeyCodeNames.shortcutLabel(for: keyCode, modifiers: modifiers)
        case .mouseRight: return "鼠标右键"
        case .mouseOther: return mouseButtonNumber.map { "鼠标按键 \($0)" } ?? "鼠标侧键"
        }
    }
}

extension TriggerOccupancy {
    init(mapping: KeyMapping) {
        self.init(
            kind: .mapping,
            ownerId: mapping.id,
            label: mapping.label,
            triggerType: mapping.triggerType,
            keyCode: mapping.keyCode,
            modifiers: mapping.modifiers,
            mouseButtonNumber: mapping.mouseButtonNumber,
            isEnabled: mapping.isEnabled
        )
    }

    init(macro: MacroAction) {
        self.init(
            kind: .macro,
            ownerId: macro.id,
            label: macro.label,
            triggerType: macro.triggerType,
            keyCode: macro.keyCode,
            modifiers: macro.modifiers,
            mouseButtonNumber: macro.mouseButtonNumber,
            isEnabled: macro.isEnabled
        )
    }
}

extension AppProfile {
    /// 本 profile 的全部触发器占用（映射在前、宏在后），供键位总览与冲突提示使用。
    var triggerOccupancies: [TriggerOccupancy] {
        mappings.map(TriggerOccupancy.init(mapping:)) + macros.map(TriggerOccupancy.init(macro:))
    }

    /// 查询某个键盘键位（忽略修饰键差异时传 nil）的占用者。纯函数，可单测。
    func occupancies(forKeyCode keyCode: UInt16) -> [TriggerOccupancy] {
        triggerOccupancies.filter { $0.triggerType == .keyboard && $0.keyCode == keyCode }
    }
}
