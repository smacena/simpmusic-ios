import Foundation

/// The user's library on the device: favourites, recently played, downloads index, and the queue
/// to restore on the next launch. Small JSON files in Application Support, written atomically.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var favorites: [Track] = []
    @Published private(set) var recent: [Track] = []
    @Published private(set) var downloaded: [Track] = []

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {
        favorites = load("favorites") ?? []
        recent = load("recent") ?? []
        downloaded = load("downloaded") ?? []
    }

    func isFavorite(_ track: Track) -> Bool { favorites.contains { $0.id == track.id } }

    func toggleFavorite(_ track: Track) {
        if let i = favorites.firstIndex(where: { $0.id == track.id }) { favorites.remove(at: i) } else { favorites.insert(track, at: 0) }
        save(favorites, "favorites")
    }

    func addRecent(_ track: Track) {
        recent.removeAll { $0.id == track.id }
        recent.insert(track, at: 0)
        if recent.count > 100 { recent.removeLast(recent.count - 100) }
        save(recent, "recent")
    }

    func markDownloaded(_ track: Track) {
        guard !downloaded.contains(where: { $0.id == track.id }) else { return }
        downloaded.insert(track, at: 0)
        save(downloaded, "downloaded")
    }

    func removeDownload(_ track: Track) {
        downloaded.removeAll { $0.id == track.id }
        save(downloaded, "downloaded")
        try? FileManager.default.removeItem(at: Downloads.fileURL(for: track.id))
    }

    // MARK: Saved queue

    struct SavedQueue: Codable {
        var tracks: [Track]
        var index: Int
        var position: Double
    }

    func saveQueue(_ queue: SavedQueue) { save(queue, "queue") }
    func savedQueue() -> SavedQueue? { load("queue") }

    // MARK: Files

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(name).json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
    }
}
