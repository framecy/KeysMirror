import SwiftUI

/// 全局设计 token。视图层禁止再出现魔法数字 / 手写透明度灰。
/// 详见 docs/UI-Redesign.md 第 4 节。
enum Theme {

    // MARK: - 间距（全部 4 的倍数）

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - 尺寸

    enum Metrics {
        /// 最小命中区：任何可点的东西——图标按钮、状态点、开关、菜单——
        /// 命中区不得小于这个值；视觉元素本身可以更小（见 `iconVisual`）。
        static let minHitTarget: CGFloat = 32
        /// 图标的视觉尺寸（区别于命中区）
        static let iconVisual: CGFloat = 15
        /// 右上角工具栏入口：比行内图标更大，作为窗口级操作要更好点
        static let toolbarIcon: CGFloat = 19
        static let toolbarHitTarget: CGFloat = 38
        /// 列表行高：32 命中区 + 上下留白
        static let rowHeight: CGFloat = 44
        /// 头栏高度
        static let headerHeight: CGFloat = 56
        /// 列表行 / 侧栏行的最小高度
        static let listRowMinHeight: CGFloat = 44

        /// 状态点直径：菜单栏面板、侧栏、状态条、动作列表统一用这一档，
        /// 只有叠在游戏画面上的游戏内 HUD 用更小的 `OverlayTypography` 系列自成一档。
        static let statusDotSize: CGFloat = 10
        /// 应用侧栏宽度
        static let sidebarWidth: CGFloat = 196
        /// 映射 Inspector 宽度（宏已改独立窗口，不再共用这个尺寸）
        static let inspectorWidth: CGFloat = 380
        /// 状态条里的分隔竖线高度
        static let dividerHeight: CGFloat = 18
        /// 头栏最左侧让开红绿灯的空间
        static let trafficLightGutter: CGFloat = 72
        /// 动作列表行里键帽所占的固定列宽，保证所有行的键位纵向对齐
        static let keyCapColumnWidth: CGFloat = 124
        /// 宏步骤卡片里的序号圆标直径
        static let stepIndexBadgeSize: CGFloat = 26
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let pill: CGFloat = 999
    }

    // MARK: - 颜色（语义色，自动适配深浅色）

    /// 一律实色，**不用任何材质 / 毛玻璃**（`.ultraThinMaterial`、`.bar` 等）：
    /// 半透明层叠在游戏画面和深色背景上很脏，且每层材质都要额外合成，代价不小。
    /// 层级靠这三档实色底 + 1px 分隔线区分。
    enum Palette {
        /// 内容底（列表 / 主区域）
        static let surface = Color(nsColor: .controlBackgroundColor)
        /// 面板底（头栏 / 侧栏 / Inspector / 状态条 / 浮层）
        static let panel = Color(nsColor: .windowBackgroundColor)
        static let separator = Color(nsColor: .separatorColor)
        static let accent = Color.accentColor
        static let success = Color.green
        static let warning = Color.orange
        static let danger = Color.red
        /// 宏的专属色，用于与映射区分（键位总览、列表图标）
        static let macro = Color.purple
        /// 键帽底：把前景色按 8% 混进面板底，得到**不透明**的浅灰
        static let keyCapFill = blend(Color(nsColor: .labelColor), into: panel, fraction: 0.08)

        /// 状态底色统一走这个函数，不再手写 0.06 / 0.08 / 0.12 / 0.18 四种灰。
        ///
        /// 注意：这里返回的是**不透明**颜色——把 `color` 按 12% 混进面板底，
        /// 而不是 `color.opacity(0.12)`。半透明底叠在深色背景 / 游戏画面上会显脏、
        /// 也会让下层内容透出来；混合色视觉相同但完全不透。
        static func tint(_ color: Color) -> Color { blend(color, into: panel, fraction: 0.12) }

        /// 把 `color` 按 `fraction` 混进 `base`，返回不透明色。
        /// 用 NSColor 在设备色彩空间里混，深浅色模式下都跟随系统底色。
        static func blend(_ color: Color, into base: Color, fraction: CGFloat) -> Color {
            let top = NSColor(color).usingColorSpace(.deviceRGB)
            let bottom = NSColor(base).usingColorSpace(.deviceRGB)
            guard let top, let bottom, let mixed = bottom.blended(withFraction: fraction, of: top) else {
                return base
            }
            return Color(nsColor: mixed.withAlphaComponent(1))
        }
    }

    // MARK: - 字体

    /// **最小字号 13pt**。macOS 的语义字体里 `.caption/.caption2/.footnote` = 10pt、
    /// `.subheadline` = 11pt、`.callout` = 12pt，全部低于下限，一律不得使用。
    ///
    /// 因此信息层级不再靠字号区分（13 已是下限，只能往上），改为靠**字重 + 颜色**：
    /// 主要信息 medium/primary，次要信息 regular/secondary，再次 tertiary。
    enum Typography {
        static let title = Font.system(size: 17, weight: .semibold)
        static let section = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let label = Font.system(size: 13, weight: .medium)
        /// 次要说明：字号同为 13，靠 `.secondary` 拉开层级
        static let caption = Font.system(size: 13)
        /// 坐标、快捷键、日志。`mono` 与旧 `monoCaption` 曾是两个 token，
        /// 13pt 下限之后二者渲染完全相同，合并成一个避免误导后来者去找差异。
        static let mono = Font.system(size: 13, design: .monospaced)
        static let keyCap = Font.system(size: 13, weight: .medium, design: .rounded)
    }

    /// 叠加在**游戏画面**上的浮层（游戏内 HUD、录制 HUD、位置指示器）单独一档。
    /// 它们不是交互界面，首要目标是少遮挡画面，因此豁免 13pt 下限（评审决议 1(c)）。
    enum OverlayTypography {
        static let title = Font.system(size: 12, weight: .semibold)
        static let body = Font.system(size: 11)
        static let mono = Font.system(size: 11, design: .monospaced)
        static let caption = Font.system(size: 10)
    }

    // MARK: - 阴影（只有一档，仅浮层使用）

    enum Shadow {
        static let color = Color.black.opacity(0.18)
        static let radius: CGFloat = 12
        static let y: CGFloat = 4
    }

    // MARK: - 动效

    /// 部署目标 macOS 13：`.snappy` / `.smooth` 需 14+，这里显式定义 spring。
    /// 使用规范见 docs/UI-Redesign.md 第 7 节：时长 ≤0.45s、位移 ≤12pt、缩放 ≤±8%。
    enum Motion {
        static let quick = Animation.easeOut(duration: 0.12)
        static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let emphasis = Animation.spring(response: 0.42, dampingFraction: 0.72)
        static let ambient = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

        /// reduceMotion 打开时返回 nil，调用点用 `.animation(Motion.standard(reduce), value:)`
        /// 直接退化为无动画。
        static func standard(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : standard }
        static func quick(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : quick }
        static func emphasis(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : emphasis }
        static func ambient(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : ambient }
    }
}

// MARK: - 便捷 modifier

extension View {
    /// 浮层外观：实色底 + 描边 + 唯一一档阴影（不用材质，理由见 Theme.Palette）
    func floatingSurface(cornerRadius: CGFloat = Theme.Radius.lg) -> some View {
        self
            .background(Theme.Palette.panel, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 1)
            )
            .shadow(color: Theme.Shadow.color, radius: Theme.Shadow.radius, y: Theme.Shadow.y)
    }

    /// 卡片外观：surface 底 + 中圆角，无阴影
    func cardSurface(cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
