import Foundation

/// The current song's lyrics, loaded once per song and shared by the player (the single line
/// shown above the title, as in SimpMusic) and the full lyrics screen.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published private(set) var lines: [LyricLine]?
    @Published private(set) var trackId: String?
    private var task: Task<Void, Never>?

    func load(for track: Track?, duration: Double) {
        guard let track, track.id != trackId else { return }
        trackId = track.id
        lines = nil
        task?.cancel()
        task = Task {
            let result = await Lyrics.fetch(for: track, duration: duration) ?? []
            guard !Task.isCancelled, self.trackId == track.id else { return }
            self.lines = result
        }
    }

    var isSynced: Bool { lines?.first.map { $0.time >= 0 } ?? false }

    func currentIndex(at position: Double) -> Int? {
        guard let lines, isSynced else { return nil }
        return lines.lastIndex { $0.time <= position }
    }
}
