import SwiftUI

/// 顶部栏图标的统一外观。诊断按钮与设置菜单**必须**共用它，不要各自再描一套。
///
/// 两个坑都在这里解决：
///
/// 1. **视觉大小**：不同 SF Symbol 的字形宽高差别很大（`stethoscope` 比 `gearshape` 明显更大），
///    只统一 `.font(size:)` 对不齐。改用 `resizable + scaledToFit + 固定方框`，
///    把两个字形都塞进同一个正方形，视觉尺寸才真正一致。
/// 2. **颜色**：菜单样式会覆盖「继承来的」前景色——设在 Menu 内层不生效，设在外层也被覆盖。
///    所以颜色作为参数**直接画在 Image 上**，不依赖任何继承链，两个入口才真正同色。
struct ToolbarIconLabel: View {
    let systemName: String
    let isHovering: Bool

    var body: some View {
        Image(systemName: systemName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(IconButton.foreground(isHovering: isHovering))
            .frame(width: Theme.Metrics.toolbarIcon, height: Theme.Metrics.toolbarIcon)
            .frame(width: Theme.Metrics.toolbarHitTarget, height: Theme.Metrics.toolbarHitTarget)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(IconButton.background(isHovering: isHovering))
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}
