import Foundation

@MainActor
final class MappingStore: ObservableObject {
    static let shared = MappingStore()

    @Published private(set) var profiles: [AppProfile] = []

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.fileURL = fileURL ?? Self.defaultFileURL()
        
        load() // Ensure data is loaded on init
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try decoder.decode([AppProfile].self, from: data)
        } catch {
            NSLog("KeysMirror decode error: \(error)")
            NSLog("KeysMirror failed to load mappings: \(error.localizedDescription)")
            profiles = []
        }
    }

    func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("KeysMirror failed to save mappings: \(error.localizedDescription)")
        }
    }

    func enabledProfile(bundleIdentifier: String) -> AppProfile? {
        profiles.first { $0.bundleIdentifier.lowercased() == bundleIdentifier.lowercased() && $0.isEnabled }
    }

    func addProfile(bundleIdentifier: String, appName: String) {
        guard !bundleIdentifier.isEmpty else { return }
        guard !profiles.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }

        profiles.append(AppProfile(bundleIdentifier: bundleIdentifier, appName: appName))
        save()
    }

    func updateProfile(_ profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func deleteProfile(_ profile: AppProfile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func addMapping(_ mapping: KeyMapping, to profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mappings.append(mapping)
        save()
    }

    func updateMapping(_ mapping: KeyMapping, in profile: AppProfile) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        guard let mappingIndex = profiles[profileIndex].mappings.firstIndex(where: { $0.id == mapping.id }) else { return }

        profiles[profileIndex].mappings[mappingIndex] = mapping
        save()
    }

    func deleteMapping(_ mapping: KeyMapping, from profile: AppProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].mappings.removeAll { $0.id == mapping.id }
        save()
    }

    static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("KeysMirror", isDirectory: true)
            .appendingPathComponent("mappings.json")
    }
}
