import Foundation

struct AppProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var bundleIdentifier: String
    var appName: String
    var mappings: [KeyMapping]
    var isEnabled: Bool
    var overlayOpacity: Double
    var showOverlay: Bool

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appName: String,
        mappings: [KeyMapping] = [],
        isEnabled: Bool = true,
        overlayOpacity: Double = 0.5,
        showOverlay: Bool = true
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.mappings = mappings
        self.isEnabled = isEnabled
        self.overlayOpacity = overlayOpacity
        self.showOverlay = showOverlay
    }
}