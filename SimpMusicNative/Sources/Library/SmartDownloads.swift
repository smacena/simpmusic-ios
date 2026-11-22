import Foundation

/// SimpMusic's smart downloads (SongRepositoryImpl.runSmartDownloads): once a day, the songs you
/// play most over the last 30 days — each play weighted by how much of the song you heard and
/// halved every 14 days — are kept downloaded, up to the chosen count. Songs this feature
/// downloaded and that fell out of the top are removed again; anything you downloaded or liked
/// yourself is never touched.
@MainActor
enum SmartDownloads {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "smart.enabled") }
    static var count: Int { max(5, UserDefaults.standard.integer(forKey: "smart.count") == 0 ? 20 : UserDefaults.standard.integer(forKey: "smart.count")) }

    private static var marked: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "smart.marked") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "smart.marked") }
    }

    static func runIfDue(force: Bool = false) {
        guard enabled else { return }
        let last = UserDefaults.standard.double(forKey: "smart.lastRun")
        guard force || Date().timeIntervalSince1970 - last > 86400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "smart.lastRun")
        let library = Library.shared
        let now = Date()
        let since = now.addingTimeInterval(-30 * 86400)
        var scores: [String: Double] = [:]
        var lastPlayed: [String: Date] = [:]
        var tracks: [String: Track] = [:]
        for play in library.plays where play.date >= since {
            let length = Double(play.track.durationText.flatMap(PlayerEngine.seconds(from:)) ?? 0)
            let heard = length > 0 ? min(1, max(0, play.seconds / length)) : 1
            let ageDays = max(0, now.timeIntervalSince(play.date) / 86400)
            scores[play.track.id, default: 0] += heard * pow(0.5, ageDays / 14)
            lastPlayed[play.track.id] = max(lastPlayed[play.track.id] ?? play.date, play.date)
            tracks[play.track.id] = play.track
        }
        let ranked = scores.keys.sorted { a, b in
            scores[a]! != scores[b]! ? scores[a]! > scores[b]! : lastPlayed[a]! > lastPlayed[b]!
        }
        var mark = marked
        // A song the user now keeps (liked, or downloaded by hand) is no longer ours to manage.
        mark = mark.filter { id in !library.isFavorite(Track(id: id, title: "", artist: "", thumbnail: nil)) || !UserDefaults.standard.bool(forKey: "download.liked") }
        var keep: [Track] = []
        for id in ranked where keep.count < count {
            guard let track = tracks[id] else { continue }
            let mine = Downloads.localFile(for: id) != nil && !mark.contains(id)
            if mine { continue }
            keep.append(track)
        }
        let keepIds = Set(keep.map(\.id))
        for id in mark where !keepIds.contains(id) {
            if let track = library.downloaded.first(where: { $0.id == id }) { library.removeDownload(track) }
            mark.remove(id)
        }
        let toFetch = keep.filter { Downloads.localFile(for: $0.id) == nil }
        mark.formUnion(keepIds)
        marked = mark
        Downloads.shared.downloadAll(toFetch)
    }
}
