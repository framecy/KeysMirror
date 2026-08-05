import SwiftUI

extension Notification.Name {
    /// 一次映射命中；userInfo 带 mappingId，overlay 据此播放水波。
    static let mappingDidTrigger = Notification.Name("KeysMirror.MappingDidTrigger")
}

enum MappingTriggerUserInfo {
    static let mappingId = "mappingId"
}

/// 游戏窗口内的位置指示器。
/// 外圈描边 + 内芯半透明填充；标签走材质底，深浅色游戏画面上都可读
/// （旧版固定黑底白字在浅色画面上会糊）。触发时播放一圈水波。
struct MappingIndicatorView: View {
    let mapping: KeyMapping
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0

    private let dotSize: CGFloat = 14

    var body: some View {
        // 只画点，不画文字标签（评审决议 2(c)）：
        // 标签要么小到违反 13pt 下限，要么大到盖住它标记的那个游戏按钮。
        // 映射叫什么在配置窗里看，游戏里只需要知道「点在哪」。
        ZStack {
            Circle()
                .strokeBorder(Theme.Palette.danger, lineWidth: 2)
                .frame(width: dotSize, height: dotSize)
                .scaleEffect(rippleScale)
                .opacity(rippleOpacity)

            Circle()
                .strokeBorder(Theme.Palette.danger, lineWidth: 2)
                .background(Circle().fill(Theme.Palette.danger.opacity(0.28)))
                .frame(width: dotSize, height: dotSize)
        }
        .help(mapping.label)
        .opacity(opacity * (appeared ? 1 : 0))
        .scaleEffect(appeared ? 1 : 0.9)
        .animation(Theme.Motion.standard(reduceMotion), value: appeared)
        .onAppear { appeared = true }
        .onReceive(NotificationCenter.default.publisher(for: .mappingDidTrigger)) { note in
            guard let id = note.userInfo?[MappingTriggerUserInfo.mappingId] as? UUID, id == mapping.id else { return }
            playRipple()
        }
    }

    private func playRipple() {
        guard !reduceMotion else { return }
        rippleScale = 1
        rippleOpacity = 0.9
        withAnimation(.easeOut(duration: 0.35)) {
            rippleScale = 2.6
            rippleOpacity = 0
        }
    }
}
