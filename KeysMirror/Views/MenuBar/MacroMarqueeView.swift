import AppKit

/// 菜单栏里横向滚动展示「运行中的宏」的自绘视图。
///
/// 为什么自绘而不是直接改 `button.title`：状态项宽度固定后，用截取字符串的方式做跑马灯，
/// 中英文混排时每帧宽度不一致会明显抖动；自绘按像素平移则完全平滑，也能精确控制裁剪。
final class MacroMarqueeView: NSView {
    /// 文本区宽度
    static let contentWidth: CGFloat = 132
    /// 左侧图标占位宽度。
    /// 图标必须由本视图自己画：NSStatusBarButton 会把 `button.image` 在整个按钮里**居中**，
    /// 状态项一旦撑到固定宽度，图标就正好压在滚动文字中间。
    static let iconWidth: CGFloat = 16
    private static let iconSize: CGFloat = 10
    /// 一轮文本结束到下一轮开头之间的留白，避免首尾粘连
    static let gap: CGFloat = 28
    /// 每帧位移，配合 30fps ≈ 21pt/s，快到能看清又不至于眼花
    static let step: CGFloat = 0.7
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    private var attributed: NSAttributedString?
    private var contentSize: CGSize = .zero
    private var offset: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 必须图层化：状态栏按钮不会在每帧重绘我们身后的背景，
        // 不开图层的话每帧的文字会叠在上一帧上，滚动时糊成一团重影。
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 关键：本视图铺满整个状态栏按钮，只负责画东西。
    /// NSView 默认会吃掉落在自己身上的鼠标事件——不返回 nil 的话，
    /// 点击全被它拦下，状态栏图标左键右键都唤不起菜单。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 图层化视图必须自己跟进 backing scale，否则在 Retina 上按 1x 渲染，
    /// 表现为文字发虚、像被压扁。
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    /// 展示文案；为空时停止动画并清空。
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            rebuild()
        }
    }

    /// 状态图标（模板图），与文案一起画在最左边。
    var icon: NSImage? {
        didSet { needsDisplay = true }
    }

    /// 图标着色；nil = 跟随系统前景色。
    var iconTint: NSColor? {
        didSet { needsDisplay = true }
    }

    // MARK: - 纯函数（可单测）

    /// 把运行中的宏拼成一行：`名称 12/50 · 名称 3/∞`
    static func compose(_ macros: [RunningMacro]) -> String {
        macros
            .map { "\($0.label) \(progressText(iteration: $0.iteration, total: $0.total))" }
            .joined(separator: "  ·  ")
    }

    /// 次数文案：有限次 `12/50`，无限 `12/∞`
    static func progressText(iteration: Int, total: Int?) -> String {
        guard let total else { return "\(iteration)/∞" }
        return "\(iteration)/\(total)"
    }

    /// 位移推进并在一轮结束后回卷，保证无缝循环。
    /// `loopWidth` = 文本宽 + 间隔；<=0 时原地不动（无内容）。
    static func advance(offset: CGFloat, by step: CGFloat, loopWidth: CGFloat) -> CGFloat {
        guard loopWidth > 0 else { return 0 }
        let next = offset + step
        return next >= loopWidth ? next - loopWidth : next
    }

    /// 内容比可视宽度窄时不滚动——短名称固定显示更易读，也避免无意义的动。
    static func shouldScroll(contentWidth: CGFloat, visibleWidth: CGFloat) -> Bool {
        contentWidth > visibleWidth
    }

    /// 文案在当前字体下的宽度。状态项据此按内容收窄——
    /// 固定宽度会让短名称左边贴着图标、右边留一大片空，看起来没居中。
    static func textWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return NSAttributedString(string: text, attributes: [.font: font]).size().width
    }

    /// 按内容决定状态项总宽（含图标），上限 iconWidth + contentWidth。
    static func preferredWidth(for text: String) -> CGFloat {
        iconWidth + min(textWidth(text) + 4, contentWidth)
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    // MARK: - 绘制

    private func rebuild() {
        guard !text.isEmpty else {
            attributed = nil
            contentSize = .zero
            stop()
            needsDisplay = true
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor.controlTextColor,
        ]
        let string = NSAttributedString(string: text, attributes: attrs)
        attributed = string
        contentSize = string.size()
        offset = 0

        if Self.shouldScroll(contentWidth: contentSize.width, visibleWidth: textAreaWidth) {
            start()
        } else {
            stop()
        }
        needsDisplay = true
    }

    /// 可视文本区宽度（总宽扣掉左侧图标位）
    private var textAreaWidth: CGFloat { max(bounds.width - Self.iconWidth, 0) }

    private func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.offset = Self.advance(
                    offset: self.offset,
                    by: Self.step,
                    loopWidth: self.contentSize.width + Self.gap
                )
                self.needsDisplay = true
            }
        }
        // .common 模式：菜单打开或窗口拖动时仍继续滚动
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 没有宏在跑时必须停掉：否则菜单栏空闲期仍有一个 30fps 的 timer 在空转。
    /// 不写 deinit —— Swift 6 的 deinit 是 nonisolated，碰不到 Timer；而这个视图是状态项
    /// 按钮的常驻子视图，生命周期与 App 相同，回收时机不构成实际问题。
    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        drawIcon()

        guard let attributed else { return }
        let textRect = NSRect(
            x: Self.iconWidth,
            y: 0,
            width: max(bounds.width - Self.iconWidth, 0),
            height: bounds.height
        )
        let y = (bounds.height - contentSize.height) / 2

        // 裁剪：滚动的文字不能画到图标上去
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: textRect).setClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard Self.shouldScroll(contentWidth: contentSize.width, visibleWidth: textRect.width) else {
            attributed.draw(at: CGPoint(x: textRect.minX, y: y))
            return
        }

        // 画两遍：本轮 + 下一轮，交界处才不会出现空档
        let loopWidth = contentSize.width + Self.gap
        attributed.draw(at: CGPoint(x: textRect.minX - offset, y: y))
        attributed.draw(at: CGPoint(x: textRect.minX - offset + loopWidth, y: y))
    }

    private func drawIcon() {
        guard let icon else { return }
        let rect = NSRect(
            x: (Self.iconWidth - Self.iconSize) / 2,
            y: (bounds.height - Self.iconSize) / 2,
            width: Self.iconSize,
            height: Self.iconSize
        )
        // 模板图直接 draw 出来是纯黑，深色菜单栏上等于看不见，所以一律着色。
        // 默认取 controlTextColor：跟随明暗外观，和菜单栏文字同色。
        NSGraphicsContext.saveGraphicsState()
        icon.draw(in: rect)
        (iconTint ?? .controlTextColor).set()
        rect.fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
    }
}
