import AppKit
import SwiftUI
import Combine

@MainActor
final class OverlayController: NSObject {
    static let shared = OverlayController()

    private var overlayPanel: NSPanel?
    private let store = MappingStore.shared
    private let windowLocator = WindowLocator.shared
    private var updateTimer: Timer?

    // 缓存上一次实际渲染的 (frame, profile)。AX 查询本身在 0.5 Hz 下可忽略（2 次/秒），
    // 但每次 SwiftUI 重建 + Window Server 调用并不便宜，仅在内容真的变化时才执行。
    private var lastRenderedFrame: CGRect?
    private var lastRenderedProfile: AppProfile?

    private override init() {
        super.init()
        // 焦点窗口位置 / 尺寸变化由 AXObserver 实时推送，无需 0.5Hz 轮询
        ActiveAppAXObserver.shared.onFocusedWindowFrameChanged = { [weak self] _ in
            self?.updateOverlay()
        }
        startSafetyTimer()
    }

    private func startSafetyTimer() {
        // AXObserver 在某些应用（特别是非原生 / iOS-on-Mac 游戏）可能漏报通知，
        // 5 秒兜底刷新一次保证 overlay 不会长期停留在过时位置。
        updateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateOverlay()
            }
        }
    }

    func updateOverlay() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let bundleId = frontApp.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier,
              let profile = store.enabledProfile(bundleIdentifier: bundleId),
              profile.showOverlay,
              !profile.mappings.isEmpty else {
            hideOverlay()
            return
        }

        // 每个 tick 重新拉一次窗口 frame（AX 调用很轻），保证窗口移动/缩放后 overlay 跟随。
        guard let frame = windowLocator.focusedWindowFrame(for: bundleId) else {
            hideOverlay()
            return
        }

        // 仅当 frame 或 profile 实际变化时，才走 SwiftUI 重建 / Window Server 调用。
        if frame == lastRenderedFrame, profile == lastRenderedProfile, overlayPanel != nil {
            return
        }

        lastRenderedFrame = frame
        lastRenderedProfile = profile
        applyFrame(frame, profile: profile)
    }

    private func applyFrame(_ axFrame: CGRect, profile: AppProfile) {
        let screenPoint = CoordinateConverter.axScreenPointToAppKit(axFrame.origin)
        let screenFrame = CGRect(
            x: screenPoint.x,
            y: screenPoint.y - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        )

        if overlayPanel == nil {
            createOverlay(in: screenFrame, profile: profile)
        } else {
            if overlayPanel?.frame != screenFrame {
                overlayPanel?.setFrame(screenFrame, display: true)
            }
            if let root = overlayPanel?.contentView as? NSHostingView<OverlayView> {
                root.rootView = OverlayView(profile: profile)
            }
            overlayPanel?.orderFrontRegardless()
        }
    }

    private func createOverlay(in frame: CGRect, profile: AppProfile) {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        let contentView = NSHostingView(rootView: OverlayView(profile: profile))
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.setFrameSize(frame.size)

        panel.contentView = contentView
        self.overlayPanel = panel
        panel.orderFrontRegardless()
    }

    private func hideOverlay() {
        if let panel = overlayPanel {
            panel.close()
            self.overlayPanel = nil
        }
        lastRenderedFrame = nil
        lastRenderedProfile = nil
    }
}

struct OverlayView: View {
    let profile: AppProfile

    var body: some View {
        // GeometryReader 给到当前 panel 的实际尺寸，
        // 配合 KeyMapping.absoluteOffset 实现窗口缩放后 overlay 红点按比例跟随。
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.clear)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                ForEach(profile.mappings) { mapping in
                    let offset = mapping.absoluteOffset(in: geo.size)
                    MappingIndicatorView(mapping: mapping, opacity: profile.overlayOpacity)
                        .position(x: offset.x, y: offset.y)
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }
}
