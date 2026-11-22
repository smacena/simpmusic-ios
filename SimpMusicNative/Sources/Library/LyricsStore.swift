import Foundation

/// The current song's lyrics, loaded once per song and shared by the player (the single line
/// shown above the title, as in SimpMusic) and the full lyrics screen.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()
    @Published private(set) var lines: [LyricLine]?
    @Published private(set) var trackId: String?
    @Published private(set) var source: LyricsSource?
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
        source = nil
        translation = [:]
        task?.cancel()
        task = Task {
            let result = await Lyrics.fetch(for: track, duration: duration)
            guard !Task.isCancelled, self.trackId == track.id else { return }
            self.lines = result?.lines ?? []
            self.source = result?.source
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

    /// Bluetooth delay compensation (ms, positive = lyrics later), applied when reading only.
    static var offsetMs: Int {
        get { UserDefaults.standard.integer(forKey: "lyrics.offsetMs") }
        set { UserDefaults.standard.set(newValue, forKey: "lyrics.offsetMs") }
    }

    func currentIndex(at position: Double) -> Int? {
        guard let lines, isSynced else { return nil }
        let heard = position - Double(Self.offsetMs) / 1000
        return lines.lastIndex { $0.time <= heard }
    }

    /// Forces a reload (after changing the preferred source).
    func reload(for track: Track?, duration: Double) {
        trackId = nil
        load(for: track, duration: duration)
    }
}
