import Foundation

/// Synced lyrics from LRCLIB (the free provider SimpMusic also uses), parsed from LRC.
struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double // seconds
    let text: String
}

enum Lyrics {
    /// Synced lyrics when any version has them, else plain lyrics. Tries the exact title, then
    /// the title without "(Ao Vivo)"/"(Live)"/"feat." decorations, then LRCLIB's search picking the
    /// synced result closest in length.
    static func fetch(for track: Track, duration: Double) async -> [LyricLine]? {
        let artist = track.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?.trimmingCharacters(in: .whitespaces) ?? track.artist
        let cleaned = clean(track.title)
        var plainFallback: [LyricLine]?
        for title in Array(Set([track.title, cleaned])) {
            guard let json = await request("get", ["track_name": title, "artist_name": artist, "duration": duration > 0 ? String(Int(duration)) : nil]) as? [String: Any] else { continue }
            if let synced = json["syncedLyrics"] as? String, !synced.isEmpty { return parse(synced) }
            if plainFallback == nil, let plain = json["plainLyrics"] as? String, !plain.isEmpty { plainFallback = plainLines(plain) }
        }
        if let results = await request("search", ["track_name": cleaned, "artist_name": artist]) as? [[String: Any]] {
            let synced = results.filter { ($0["syncedLyrics"] as? String)?.isEmpty == false }
            let best = synced.min { abs(($0["duration"] as? Double ?? 0) - duration) < abs(($1["duration"] as? Double ?? 0) - duration) }
            if let lrc = best?["syncedLyrics"] as? String { return parse(lrc) }
            if plainFallback == nil, let plain = results.first?["plainLyrics"] as? String, !plain.isEmpty { plainFallback = plainLines(plain) }
        }
        return plainFallback
    }

    private static func clean(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*(ao vivo|live|feat\.?|ft\.?|remaster|vers[aã]o|ac[uú]stic)[^\)\]]*[\)\]]"#, #"\s+-\s+.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func plainLines(_ text: String) -> [LyricLine] {
        text.split(separator: "\n").enumerated().map { LyricLine(id: $0.offset, time: -1, text: String($0.element)) }
    }

    private static func request(_ endpoint: String, _ params: [String: String?]) async -> Any? {
        var comps = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        comps.queryItems = params.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("SimpMusic-iOS-personal", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Community translation from SimpMusic Lyrics (the service the SimpMusic apps use), as LRC
    /// lines, in [language] (two letters). Nil when nobody translated this song yet.
    static func translation(videoId: String, language: String) async -> [LyricLine]? {
        guard let url = URL(string: "https://api-lyrics.simpmusic.org/v1/translated/\(videoId)/\(language)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("SimpMusicLyrics/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let object = (json as? [String: Any]) ?? ((json as? [[String: Any]])?.max { ($0["vote"] as? Int ?? 0) < ($1["vote"] as? Int ?? 0) })
        guard let lrc = object?["translatedLyric"] as? String, !lrc.isEmpty else { return nil }
        let lines = parse(lrc)
        return lines.isEmpty ? nil : lines
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in lrc.split(separator: "\n") {
            let s = String(raw)
            let matches = pattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
            guard let last = matches.last, let textRange = Range(last.range, in: s) else { continue }
            let text = String(s[textRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            for m in matches {
                guard let mr = Range(m.range(at: 1), in: s), let sr = Range(m.range(at: 2), in: s) else { continue }
                let t = (Double(s[mr]) ?? 0) * 60 + (Double(s[sr]) ?? 0)
                lines.append(LyricLine(id: lines.count, time: t, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}
