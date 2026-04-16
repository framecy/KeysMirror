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

    // Cache: avoid redundant AX IPC + Window Server calls when nothing changed
    private var lastFrameBundleId: String?
    private var lastWindowFrame: CGRect?
    private var lastProfileVersion: Int = 0

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
        // Clear cache so the next tick does a fresh AX query for the new app
        lastFrameBundleId = nil
        lastWindowFrame = nil
        updateOverlay()
    }

    private func startTimer() {
        // 0.5 Hz is plenty for a static overlay; the cache means most ticks are
        // near-zero cost when the game window hasn't moved
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

        // Profile version fingerprint: skip SwiftUI update when unchanged
        let profileVersion = profile.mappings.count &+ Int(profile.overlayOpacity * 1000)

        // Skip the AX IPC call entirely when app and window frame are unchanged
        if bundleId == lastFrameBundleId, let cachedFrame = lastWindowFrame {
            if overlayPanel != nil && profileVersion == lastProfileVersion {
                // Nothing changed — no AX call, no Window Server message needed
                return
            }
            // Profile changed but frame is still valid — update SwiftUI view only
            applyFrame(cachedFrame, profile: profile)
            lastProfileVersion = profileVersion
            return
        }

        guard let frame = windowLocator.focusedWindowFrame(for: bundleId) else {
            hideOverlay()
            return
        }

        lastFrameBundleId = bundleId
        lastWindowFrame = frame
        lastProfileVersion = profileVersion

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
            // Only call orderFrontRegardless when the panel needs to come forward
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
        lastFrameBundleId = nil
        lastWindowFrame = nil
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
