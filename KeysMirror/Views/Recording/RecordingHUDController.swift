import AppKit
import SwiftUI

/// 录制期间的浮动提示条。
/// nonactivating panel：显示在最上层但不抢焦点，用户可以继续在目标 app 里正常点击。
@MainActor
final class RecordingHUDController {
    static let shared = RecordingHUDController()

    private var panel: NSPanel?
    private let model = RecordingHUDModel()

    private init() {}

    func show(title: String, subtitle: String, showsClickCount: Bool) {
        model.title = title
        model.subtitle = subtitle
        model.showsClickCount = showsClickCount
        model.clickCount = 0
        model.rejectionHint = nil

        if panel == nil {
            let size = CGSize(width: 320, height: 64)
            let hosting = NSHostingView(rootView: RecordingHUDView(model: model))
            hosting.setFrameSize(size)

            let p = NSPanel(
                contentRect: CGRect(origin: Self.topCenterOrigin(for: size), size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false          // 阴影由 SwiftUI 的 floatingSurface 负责
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.isMovable = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            p.contentView = hosting
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func updateClickCount(_ count: Int) {
        model.clickCount = count
        model.pulse()
    }

    /// 点在目标窗口外：提示 + 抖动
    func rejectClick(hint: String) {
        model.reject(hint: hint)
    }

    func hide() {
        panel?.close()
        panel = nil
    }

    private static func topCenterOrigin(for size: CGSize) -> CGPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height - Theme.Spacing.md)
    }
}

@MainActor
final class RecordingHUDModel: ObservableObject {
    @Published var title: String = ""
    @Published var subtitle: String = ""
    @Published var showsClickCount = false
    @Published var clickCount = 0
    @Published var rejectionHint: String?
    /// 每次捕获 +1，驱动计数回弹动画
    @Published var pulseToken = 0
    /// 每次拒绝 +1，驱动抖动
    @Published var shakeToken = 0

    private var hintTask: Task<Void, Never>?

    func pulse() { pulseToken += 1 }

    func reject(hint: String) {
        rejectionHint = hint
        shakeToken += 1
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.rejectionHint = nil
        }
    }
}

struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var breathing = false
    @State private var countScale: CGFloat = 1
    @State private var shakeOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Circle()
                .fill(Theme.Palette.danger)
                .frame(width: 10, height: 10)
                .opacity(breathing && !reduceMotion ? 0.35 : 1)
                .animation(Theme.Motion.ambient(reduceMotion), value: breathing)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .font(Theme.OverlayTypography.title)
                Text(model.rejectionHint ?? model.subtitle)
                    .font(Theme.OverlayTypography.body)
                    .foregroundStyle(model.rejectionHint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.Palette.warning))
            }

            Spacer(minLength: 0)

            if model.showsClickCount {
                VStack(spacing: 0) {
                    Text("\(model.clickCount)")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .scaleEffect(countScale)
                    Text("次点击")
                        .font(Theme.OverlayTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .floatingSurface()
        .offset(x: shakeOffset)
        .onAppear { breathing = true }
        .onChange(of: model.pulseToken) { _ in bounceCount() }
        .onChange(of: model.shakeToken) { _ in shake() }
    }

    private func bounceCount() {
        guard !reduceMotion else { return }
        withAnimation(Theme.Motion.emphasis) { countScale = 1.25 }
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(Theme.Motion.emphasis) { countScale = 1 }
        }
    }

    private func shake() {
        guard !reduceMotion else { return }
        Task {
            for offset in [CGFloat(-4), 4, -3, 3, 0] {
                withAnimation(Theme.Motion.quick) { shakeOffset = offset }
                try? await Task.sleep(nanoseconds: 55_000_000)
            }
        }
    }
}
