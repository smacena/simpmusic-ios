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
                              "reverb.enabled", "reverb.preset", "reverb.mix", "normalizeVolume", "crossfade.enabled", "crossfade.seconds",
                              "skipSilence", "pitch.semitones", "eightd.enabled", "eightd.direction", "eightd.period",
                              "player.style", "theme.accent", "lyrics.style", "lyrics.source", "lyrics.offsetMs", "lyrics.translate", "lyrics.translateLang",
                              "quality.audio", "quality.video", "content.country", "content.language", "content.explicit", "video.auto",
                              "radio.audioOnly", "player.saveModes", "history.tracking", "download.liked", "sponsorblock.enabled",
                              "sponsorblock.categories", "backup.auto", "backup.days", "backup.keep"]

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

    /// Settings → Backup automático: once every N days (on opening the app), keeping the newest K files.
    @MainActor
    static func autoBackupIfDue() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "backup.auto") else { return }
        let days = max(1, d.integer(forKey: "backup.days") == 0 ? 7 : d.integer(forKey: "backup.days"))
        let last = d.double(forKey: "backup.last")
        guard Date().timeIntervalSince1970 - last > Double(days) * 86400 else { return }
        guard (try? export()) != nil else { return }
        d.set(Date().timeIntervalSince1970, forKey: "backup.last")
        let keep = max(1, d.integer(forKey: "backup.keep") == 0 ? 5 : d.integer(forKey: "backup.keep"))
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("backups", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("SimpMusic-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        files.dropFirst(keep).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    static var lastBackup: Date? {
        let t = UserDefaults.standard.double(forKey: "backup.last")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
}
