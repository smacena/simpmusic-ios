import Foundation

/// Offline songs: the AAC stream saved as Documents/downloads/<videoId>.m4a (visible in the Files
/// app). The player prefers this file over the network.
@MainActor
final class Downloads: ObservableObject {
    static let shared = Downloads()
    @Published private(set) var inProgress: Set<String> = []

    nonisolated static func fileURL(for id: String) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(id).m4a")
    }

    nonisolated static func localFile(for id: String) -> URL? {
        let url = fileURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// googlevideo serves a single whole-file request at about playback speed, but byte ranges at
    /// full speed, so the file is fetched in 1 MB pieces (what SimpMusic's downloader does too).
    nonisolated static func fetchInChunks(_ url: URL, to file: URL) async throws {
        let chunk = 1 << 20
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var start = 0
        var total: Int?
        while total == nil || start < total! {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(start)-\(start + chunk - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw InnerTubeError.badResponse }
            if http.statusCode == 416 { break }
            guard http.statusCode == 206 || http.statusCode == 200 else { throw InnerTubeError.http(http.statusCode) }
            if total == nil, let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
                total = Int(range[range.index(after: slash)...])
            }
            try handle.write(contentsOf: data)
            start += data.count
            if http.statusCode == 200 || data.count < chunk { break }
        }
    }

    @Published private(set) var batchRemaining = 0

    /// Downloads a whole list one song at a time (gentle on the network and on YouTube).
    func downloadAll(_ tracks: [Track]) {
        let pending = tracks.filter { Self.localFile(for: $0.id) == nil && !inProgress.contains($0.id) }
        guard !pending.isEmpty else { return }
        batchRemaining += pending.count
        Task {
            for track in pending {
                await downloadNow(track)
                batchRemaining = max(0, batchRemaining - 1)
            }
        }
    }

    private func downloadNow(_ track: Track) async {
        guard !inProgress.contains(track.id), Self.localFile(for: track.id) == nil else { return }
        inProgress.insert(track.id)
        defer { inProgress.remove(track.id) }
        do {
            let stream = try await InnerTube.shared.audioStream(for: track.id, forDownload: true)
            let target = Self.fileURL(for: track.id)
            let partial = target.appendingPathExtension("part")
            try await Self.fetchInChunks(stream.url, to: partial)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            Library.shared.markDownloaded(track)
        } catch {
            NSLog("SimpNative: download failed for \(track.id): \(error)")
        }
    }

    func download(_ track: Track) {
        guard !inProgress.contains(track.id), Self.localFile(for: track.id) == nil else { return }
        inProgress.insert(track.id)
        Task {
            defer { inProgress.remove(track.id) }
            do {
                let stream = try await InnerTube.shared.audioStream(for: track.id, forDownload: true)
                let target = Self.fileURL(for: track.id)
                let partial = target.appendingPathExtension("part")
                try await Self.fetchInChunks(stream.url, to: partial)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
                Library.shared.markDownloaded(track)
            } catch {
                NSLog("SimpNative: download failed for \(track.id): \(error)")
            }
        }
    }
}
