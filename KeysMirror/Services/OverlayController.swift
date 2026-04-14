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

    private override init() {
        super.init()
        setupNotification()
        startTimer()
    }

    private func setupNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appSwitched),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appSwitched() {
        updateOverlay()
    }

    private func startTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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

        guard let frame = windowLocator.focusedWindowFrame(for: bundleId) else {
            hideOverlay()
            return
        }

        // AX frame (top-left origin, Y down) → AppKit NSPanel frame (bottom-left origin, Y up)
        let screenPoint = CoordinateConverter.axScreenPointToAppKit(frame.origin)
        let screenFrame = CGRect(
            x: screenPoint.x,
            y: screenPoint.y - frame.height,
            width: frame.width,
            height: frame.height
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
        }

        overlayPanel?.orderFrontRegardless()
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
    }
}

struct OverlayView: View {
    let profile: AppProfile

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ForEach(profile.mappings) { mapping in
                MappingIndicatorView(mapping: mapping, opacity: profile.overlayOpacity)
                    .position(x: mapping.relativeX, y: mapping.relativeY)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .allowsHitTesting(false)
    }
}
