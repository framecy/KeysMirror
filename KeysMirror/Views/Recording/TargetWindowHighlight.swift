import AppKit
import SwiftUI

/// 录制期间给目标窗口画一圈呼吸描边：明确「点在这个窗口里才算数」。
/// 与 OverlayController 一样是穿透的 nonactivating panel，跟随窗口 frame 变化。
@MainActor
final class TargetWindowHighlight {
    static let shared = TargetWindowHighlight()

    private var panel: NSPanel?
    private var bundleIdentifier: String?
    private var frameObserver: NSObjectProtocol?

    private init() {}

    func show(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        applyCurrentFrame()

        if frameObserver == nil {
            frameObserver = NotificationCenter.default.addObserver(
                forName: .focusedWindowFrameChanged,
                object: nil,
                queue: .main
            ) { _ in
                assumingMainActor { TargetWindowHighlight.shared.applyCurrentFrame() }
            }
        }
    }

    func hide() {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        panel?.close()
        panel = nil
        bundleIdentifier = nil
    }

    private func applyCurrentFrame() {
        guard let bundleIdentifier,
              let axFrame = WindowLocator.shared.focusedWindowFrame(for: bundleIdentifier) else {
            panel?.orderOut(nil)
            return
        }

        // AX 坐标（原点左上）→ AppKit 屏幕坐标（原点左下）
        let topLeft = CoordinateConverter.axScreenPointToAppKit(axFrame.origin)
        let screenFrame = CGRect(
            x: topLeft.x,
            y: topLeft.y - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )

        if panel == nil {
            let p = NSPanel(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.isMovable = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            let hosting = NSHostingView(rootView: TargetWindowHighlightView())
            hosting.setFrameSize(screenFrame.size)
            p.contentView = hosting
            panel = p
        } else if panel?.frame != screenFrame {
            panel?.setFrame(screenFrame, display: true)
            panel?.contentView?.setFrameSize(screenFrame.size)
        }
        panel?.orderFrontRegardless()
    }
}

struct TargetWindowHighlightView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.md)
            .strokeBorder(Theme.Palette.danger, lineWidth: 2)
            .opacity(breathing && !reduceMotion ? 0.35 : 0.9)
            .animation(Theme.Motion.ambient(reduceMotion), value: breathing)
            .allowsHitTesting(false)
            .onAppear { breathing = true }
    }
}
