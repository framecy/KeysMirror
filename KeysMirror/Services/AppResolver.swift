import AppKit

struct RunningApplication: Identifiable, Hashable {
    let id: String
    let bundleIdentifier: String
    let displayName: String
    let icon: NSImage?
}

@MainActor
final class AppResolver {
    static let shared = AppResolver()

    private init() {}

    func runningApplications() -> [RunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bundleIdentifier = app.bundleIdentifier else { return nil }
                return RunningApplication(
                    id: bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    displayName: app.localizedName ?? bundleIdentifier,
                    icon: app.icon
                )
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func runningApplication(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func activate(bundleIdentifier: String) -> Bool {
        guard let application = runningApplication(bundleIdentifier: bundleIdentifier) else {
            return false
        }

        application.unhide()
        return application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}
