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
    /// 看门狗：上一次 AXObserver 推送时间戳；若 timer tick 发现距上次推送 > 阈值且 overlay 显示中，才强制刷新。
    private var lastFrameUpdate: Date?

    private static let safetyInterval: TimeInterval = 5.0
    private static let safetyStaleThreshold: TimeInterval = 4.5

    private override init() {
        super.init()
        // 焦点窗口位置 / 尺寸变化由 AXObserver 实时推送
        NotificationCenter.default.addObserver(
            forName: .focusedWindowFrameChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lastFrameUpdate = Date()
                self?.updateOverlay()
            }
        }
        // 启动时不立即跑 timer：等到 overlay 真的需要展示时再启
    }

    /// AXObserver 在某些应用（特别是非原生 / iOS-on-Mac 游戏）可能漏报通知。
    /// 看门狗策略：只在 overlay 当前显示中且距上次 AX 推送已超阈值时，才主动刷新。
    /// 空闲（无 overlay 或前台无 profile）下 timer 不运行，零 AX IPC。
    private func startSafetyTimerIfNeeded() {
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.safetyTick()
            }
        }
    }

    private func stopSafetyTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func safetyTick() {
        // overlay 不在显示就不查 AX
        guard overlayPanel != nil else {
            stopSafetyTimer()
            return
        }
        // AXObserver 最近推送过就不重复查
        if let last = lastFrameUpdate, Date().timeIntervalSince(last) < Self.safetyStaleThreshold {
            return
        }
        updateOverlay()
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
        // overlay 现在显示了，启动看门狗保兜底
        startSafetyTimerIfNeeded()
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

    func hideOverlay() {
        if let panel = overlayPanel {
            panel.close()
            self.overlayPanel = nil
        }
        lastRenderedFrame = nil
        lastRenderedProfile = nil
        // overlay 已隐藏，停掉看门狗
        stopSafetyTimer()
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

                ForEach(profile.mappings.filter { $0.isEnabled }) { mapping in
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
