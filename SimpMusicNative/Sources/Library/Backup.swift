import Foundation

/// Backup of the library (favourites, recent, downloads list, saved queue) and every setting, as
/// one JSON file. Written to Documents/backups (visible in the Files app) and shared from there.
/// The YouTube session is deliberately not included: it stays in this device's Keychain.
enum Backup {
    struct Payload: Codable {
        var version = 1
        var favorites: [Track]
        var recent: [Track]
        var downloaded: [Track]
        var queue: Library.SavedQueue?
        var settings: [String: String]
    }

    static let settingKeys = ["eq.enabled", "eq.gains", "eq.preamp", "delay.enabled", "delay.time", "delay.feedback", "delay.mix",
                              "reverb.enabled", "reverb.preset", "reverb.mix", "normalizeVolume", "crossfade.enabled", "crossfade.seconds"]

    @MainActor
    static func export() throws -> URL {
        let defaults = UserDefaults.standard
        var settings: [String: String] = [:]
        for key in settingKeys {
            if let value = defaults.object(forKey: key),
               let data = try? JSONSerialization.data(withJSONObject: [value]),
               let text = String(data: data, encoding: .utf8) { settings[key] = text }
        }
        let library = Library.shared
        let payload = Payload(favorites: library.favorites, recent: library.recent, downloaded: library.downloaded,
                              queue: library.savedQueue(), settings: settings)
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("SimpMusic-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: .atomic)
        return url
    }

    @MainActor
    static func restore(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        Library.shared.replaceAll(favorites: payload.favorites, recent: payload.recent, downloaded: payload.downloaded, queue: payload.queue)
        let defaults = UserDefaults.standard
        for (key, text) in payload.settings where settingKeys.contains(key) {
            if let data = text.data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [Any], let value = array.first {
                defaults.set(value, forKey: key)
            }
        }
    }
}
