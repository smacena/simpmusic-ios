import Foundation

/// The current song's lyrics, loaded once per song and shared by the player (the single line
/// shown above the title, as in SimpMusic) and the full lyrics screen.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published private(set) var lines: [LyricLine]?
    @Published private(set) var trackId: String?
    /// Translated lines keyed by their time, when a community translation exists.
    @Published private(set) var translation: [Double: String] = [:]

    static var translateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "lyrics.translate") }
        set { UserDefaults.standard.set(newValue, forKey: "lyrics.translate") }
    }
    private var task: Task<Void, Never>?

    func load(for track: Track?, duration: Double) {
        guard let track, track.id != trackId else { return }
        trackId = track.id
        lines = nil
        translation = [:]
        task?.cancel()
        task = Task {
            let result = await Lyrics.fetch(for: track, duration: duration) ?? []
            guard !Task.isCancelled, self.trackId == track.id else { return }
            self.lines = result
            guard Self.translateEnabled, let language = Locale.current.language.languageCode?.identifier,
                  let translated = await Lyrics.translation(videoId: track.id, language: language),
                  self.trackId == track.id else { return }
            var map: [Double: String] = [:]
            for line in translated where line.time >= 0 { map[(line.time * 10).rounded() / 10] = line.text }
            self.translation = map
        }
    }

    /// The translation of [line], matched by timestamp (to the tenth of a second).
    func translated(_ line: LyricLine) -> String? {
        guard line.time >= 0 else { return nil }
        return translation[(line.time * 10).rounded() / 10]
    }

    var isSynced: Bool { lines?.first.map { $0.time >= 0 } ?? false }

    func currentIndex(at position: Double) -> Int? {
        guard let lines, isSynced else { return nil }
        return lines.lastIndex { $0.time <= position }
    }
}
