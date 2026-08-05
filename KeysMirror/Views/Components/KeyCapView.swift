import SwiftUI

/// 把触发器渲染成一排键帽：`[⌃][⇧][K]`；鼠标触发渲染成鼠标图标 + 说明。
/// 列表行、Inspector、HUD、键位总览共用。
struct KeyCapView: View {
    enum Trigger: Hashable {
        case keyboard(keyCode: UInt16, modifiers: UInt64)
        case mouseRight
        case mouseOther(buttonNumber: Int?)
        /// 尚未录制
        case none
    }

    let trigger: Trigger

    init(trigger: Trigger) {
        self.trigger = trigger
    }

    /// 便捷入口：直接从映射 / 宏的字段构造
    init(triggerType: TriggerType, keyCode: UInt16, modifiers: UInt64, mouseButtonNumber: Int?) {
        switch triggerType {
        case .keyboard: self.trigger = .keyboard(keyCode: keyCode, modifiers: modifiers)
        case .mouseRight: self.trigger = .mouseRight
        case .mouseOther: self.trigger = .mouseOther(buttonNumber: mouseButtonNumber)
        }
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            switch trigger {
            case .keyboard(let keyCode, let modifiers):
                ForEach(CGKeyCodeNames.capSymbols(for: keyCode, modifiers: modifiers), id: \.self) { cap($0) }
            case .mouseRight:
                mouseCap(symbol: "cursorarrow.click", text: "右键")
            case .mouseOther(let number):
                mouseCap(symbol: "cursorarrow.click.2", text: number.map { "键 \($0)" } ?? "侧键")
            case .none:
                Text("未录制")
                    .font(Theme.Typography.keyCap)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func cap(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.keyCap)
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 24)
            .background(Theme.Palette.keyCapFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 1)
            )
    }

    private func mouseCap(symbol: String, text: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(Theme.Typography.keyCap)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.Palette.keyCapFill, in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(Theme.Palette.separator, lineWidth: 1)
        )
    }

    private var accessibilityText: String {
        switch trigger {
        case .keyboard(let keyCode, let modifiers):
            return CGKeyCodeNames.shortcutLabel(for: keyCode, modifiers: modifiers)
        case .mouseRight: return "鼠标右键"
        case .mouseOther(let number): return number.map { "鼠标按键 \($0)" } ?? "鼠标侧键"
        case .none: return "未录制触发器"
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        KeyCapView(trigger: .keyboard(keyCode: 0x0C, modifiers: 0))
        KeyCapView(trigger: .keyboard(keyCode: 0x28, modifiers: 0x40000 | 0x20000))
        KeyCapView(trigger: .mouseRight)
        KeyCapView(trigger: .mouseOther(buttonNumber: 4))
        KeyCapView(trigger: .none)
    }
    .padding()
}
