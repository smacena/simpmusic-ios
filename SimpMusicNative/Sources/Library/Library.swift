import Foundation

/// The user's library on the device: favourites, recently played, downloads index, and the queue
/// to restore on the next launch. Small JSON files in Application Support, written atomically.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var favorites: [Track] = []
    @Published private(set) var recent: [Track] = []
    @Published private(set) var downloaded: [Track] = []
    @Published private(set) var playlists: [LocalPlaylist] = []

    struct LocalPlaylist: Identifiable, Codable, Hashable {
        var id = UUID()
        var name: String
        var tracks: [Track]
    }

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {
        favorites = load("favorites") ?? []
        recent = load("recent") ?? []
        downloaded = load("downloaded") ?? []
        playlists = load("playlists") ?? []
    }

    // MARK: Own playlists

    @discardableResult
    func createPlaylist(_ name: String) -> LocalPlaylist {
        let playlist = LocalPlaylist(name: name.isEmpty ? "Nova playlist" : name, tracks: [])
        playlists.insert(playlist, at: 0)
        save(playlists, "playlists")
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        playlists[i].name = name
        save(playlists, "playlists")
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save(playlists, "playlists")
    }

    func add(_ track: Track, to id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }), !playlists[i].tracks.contains(where: { $0.id == track.id }) else { return }
        playlists[i].tracks.append(track)
        save(playlists, "playlists")
    }

    func remove(at offsets: IndexSet, from id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
        save(playlists, "playlists")
    }

    func move(from source: IndexSet, to destination: Int, in id: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
        save(playlists, "playlists")
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

    /// Used by backup restore.
    func replaceAll(favorites: [Track], recent: [Track], downloaded: [Track], queue: SavedQueue?) {
        self.favorites = favorites
        self.recent = recent
        // Only songs whose file is actually on this device count as downloaded.
        self.downloaded = downloaded.filter { Downloads.localFile(for: $0.id) != nil }
        save(self.favorites, "favorites")
        save(self.recent, "recent")
        save(self.downloaded, "downloaded")
        if let queue { saveQueue(queue) }
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
