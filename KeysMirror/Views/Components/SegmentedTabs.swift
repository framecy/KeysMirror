import SwiftUI

/// 分段切换控件。
///
/// 替代 `.pickerStyle(.segmented)`：系统样式会在每两个分段之间画一条竖分隔线，
/// 视觉噪音大且和这个 App 其它地方的胶囊风格不统一。这里用「选中项浮起一枚胶囊」
/// 的方式表达选中态——不需要分隔线也能读清楚边界。
///
/// ⚠️ **本类型必须保持非泛型**。
/// 最初写成 `SegmentedTabs<Value: Hashable>` + `@Binding var selection: Value`，
/// 在宏编辑器里必现 EXC_BAD_ACCESS（KERN_INVALID_ADDRESS at 0x1e）。崩溃日志的
/// 寄存器状态是决定性证据：
///
///     x22: type metadata for MacroEditorViewModel.RepeatMode
///     x28: protocol witness table for DispatchMainExecutor
///     栈顶: swift_task_isCurrentExecutorWithFlags ← closure #1 in SegmentedTabs.body
///     相关帧全部标记为 "specialized ..."
///
/// 即泛型参数的**类型元数据被放到了 executor 身份对象的位置**，运行时对它取 isa 就炸。
/// 这是当前工具链（Xcode 27 / Swift 6 / macOS 27 beta）特化「泛型 View + body 的
/// MainActor 动态校验」时的 codegen 缺陷，与本控件的业务逻辑无关——
/// 换 matchedGeometryEffect、换 ForEach 写法都不解决，只有去掉泛型才行。
///
/// 因此这里只收下标与标题（都是具体类型），由调用方负责和自己的枚举互转。
struct SegmentedTabs: View {
    let titles: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            // 显式 Array(...)：裸写 titles.indices 会和 indices(where:) 重载撞上
            ForEach(Array(titles.indices), id: \.self) { index in
                let isSelected = index == selectedIndex
                Text(titles[index])
                    .font(Theme.Typography.label)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, Theme.Spacing.md)
                    .frame(height: Theme.Metrics.minHitTarget - 4)
                    // 胶囊恒定存在、用 opacity 切换，不做条件插入
                    .background(
                        Capsule()
                            .fill(Theme.Palette.accent)
                            .opacity(isSelected ? 1 : 0)
                    )
                    .contentShape(Capsule())
                    .onTapGesture { onSelect(index) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.Palette.tint(.gray)))
        .animation(Theme.Motion.quick(reduceMotion), value: selectedIndex)
    }
}
