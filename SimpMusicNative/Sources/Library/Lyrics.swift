import Foundation

/// Synced lyrics from LRCLIB (the free provider SimpMusic also uses), parsed from LRC.
struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: Double // seconds
    let text: String
    /// Word-by-word timing (rich sync), when the source has it.
    var words: [LyricWord]? = nil
}

struct LyricWord: Hashable {
    let time: Double
    let text: String
}

/// Where lyrics come from, in the order tried (the first one the user picks goes first).
enum LyricsSource: String, CaseIterable, Identifiable {
    case simpmusic = "SimpMusic Lyrics", better = "BetterLyrics", lrclib = "LRCLIB", youtube = "YouTube"
    var id: String { rawValue }
    static var preferred: LyricsSource {
        get { LyricsSource(rawValue: UserDefaults.standard.string(forKey: "lyrics.source") ?? "") ?? .simpmusic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lyrics.source") }
    }
}

enum Lyrics {
    /// Synced lyrics when any version has them, else plain lyrics. Tries the exact title, then
    /// the title without "(Ao Vivo)"/"(Live)"/"feat." decorations, then LRCLIB's search picking the
    /// synced result closest in length.
    /// Tries every source, preferred first; synced (ideally word-by-word) beats plain text.
    static func fetch(for track: Track, duration: Double) async -> (lines: [LyricLine], source: LyricsSource)? {
        let order = [LyricsSource.preferred] + LyricsSource.allCases.filter { $0 != .preferred }
        var plain: (lines: [LyricLine], source: LyricsSource)?
        for source in order {
            let lines: [LyricLine]?
            switch source {
            case .simpmusic: lines = await simpMusic(track)
            case .better: lines = await betterLyrics(track, duration: duration)
            case .lrclib: lines = await lrclib(for: track, duration: duration)
            case .youtube: lines = await InnerTube.shared.youtubeLyrics(for: track.id).map(plainLines)
            }
            guard let lines, !lines.isEmpty else { continue }
            if lines.first!.time >= 0 { return (lines, source) }
            if plain == nil { plain = (lines, source) }
        }
        return plain
    }

    private static func primaryArtist(_ track: Track) -> String {
        track.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?.trimmingCharacters(in: .whitespaces) ?? track.artist
    }

    /// SimpMusic's own community database, keyed by videoId (rich sync when available).
    private static func simpMusic(_ track: Track) async -> [LyricLine]? {
        guard let url = URL(string: "https://api-lyrics.simpmusic.org/v1/\(track.id)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("SimpMusicLyrics/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await Net.session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let list: [[String: Any]] = (json as? [[String: Any]]) ?? ((json as? [String: Any]).map { ($0["data"] as? [[String: Any]]) ?? [$0] } ?? [])
        guard let best = list.max(by: { ($0["vote"] as? Int ?? 0) < ($1["vote"] as? Int ?? 0) }) else { return nil }
        if let rich = best["richSyncLyrics"] as? String, !rich.isEmpty {
            let lines = parse(rich)
            if !lines.isEmpty { return lines }
        }
        if let synced = best["syncedLyrics"] as? String, !synced.isEmpty { return parse(synced) }
        if let plain = best["plainLyric"] as? String, !plain.isEmpty { return plainLines(plain) }
        return nil
    }

    /// BetterLyrics (Apple Music-sourced TTML, often word-by-word).
    private static func betterLyrics(_ track: Track, duration: Double) async -> [LyricLine]? {
        var comps = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics")!
        comps.queryItems = [URLQueryItem(name: "s", value: clean(track.title)), URLQueryItem(name: "a", value: primaryArtist(track))]
        if duration > 0 { comps.queryItems?.append(URLQueryItem(name: "d", value: String(Int(duration)))) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("SimpMusicLyrics/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await Net.session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ttml = json["ttml"] as? String, !ttml.isEmpty else { return nil }
        return parseTTML(ttml)
    }

    static func parseTTML(_ ttml: String) -> [LyricLine] {
        let pRegex = try! NSRegularExpression(pattern: #"<p\s[^>]*begin="([^"]+)"[^>]*>([\s\S]*?)</p>"#)
        let spanRegex = try! NSRegularExpression(pattern: #"<span\s[^>]*begin="([^"]+)"[^>]*>([^<]*)</span>"#)
        var lines: [LyricLine] = []
        let ns = ttml as NSString
        for p in pRegex.matches(in: ttml, range: NSRange(location: 0, length: ns.length)) {
            let begin = ttmlTime(ns.substring(with: p.range(at: 1)))
            let inner = ns.substring(with: p.range(at: 2)) as NSString
            var words: [LyricWord] = []
            for sp in spanRegex.matches(in: inner as String, range: NSRange(location: 0, length: inner.length)) {
                let w = decodeEntities(inner.substring(with: sp.range(at: 2))).trimmingCharacters(in: .whitespaces)
                if !w.isEmpty { words.append(LyricWord(time: ttmlTime(inner.substring(with: sp.range(at: 1))), text: w)) }
            }
            let text = words.isEmpty
                ? decodeEntities((inner as String).replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)).trimmingCharacters(in: .whitespacesAndNewlines)
                : words.map(\.text).joined(separator: " ")
            guard !text.isEmpty else { continue }
            lines.append(LyricLine(id: lines.count, time: begin, text: text, words: words.isEmpty ? nil : words))
        }
        return lines
    }

    private static func ttmlTime(_ s: String) -> Double {
        let parts = s.replacingOccurrences(of: "s", with: "").split(separator: ":").map { Double($0) ?? 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func lrclib(for track: Track, duration: Double) async -> [LyricLine]? {
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

    static func plainLines(_ text: String) -> [LyricLine] {
        text.split(separator: "\n").enumerated().map { LyricLine(id: $0.offset, time: -1, text: String($0.element)) }
    }

    private static func request(_ endpoint: String, _ params: [String: String?]) async -> Any? {
        var comps = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        comps.queryItems = params.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("SimpMusic-iOS-personal", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await Net.session.data(for: req),
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
        guard let (data, response) = try? await Net.session.data(for: req),
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
            var body = String(s[textRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            body = body.replacingOccurrences(of: #"^v\d+:\s*"#, with: "", options: .regularExpression)
            let words = richWords(body)
            let text = words.map { $0.map(\.text).joined(separator: " ") } ?? body
            for m in matches {
                guard let mr = Range(m.range(at: 1), in: s), let sr = Range(m.range(at: 2), in: s) else { continue }
                let t = (Double(s[mr]) ?? 0) * 60 + (Double(s[sr]) ?? 0)
                lines.append(LyricLine(id: lines.count, time: t, text: text, words: words))
            }
        }
        return lines.sorted { $0.time < $1.time }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text, words: $0.element.words) }
    }

    /// "<00:12.30> word <00:12.80> next" → timed words; nil when the line has no word markers.
    static func richWords(_ body: String) -> [LyricWord]? {
        let regex = try! NSRegularExpression(pattern: #"<(\d+):(\d+(?:\.\d+)?)>"#)
        let ns = body as NSString
        let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var words: [LyricWord] = []
        for (i, m) in matches.enumerated() {
            let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
            let start = m.range.location + m.range.length
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let w = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
            if !w.isEmpty { words.append(LyricWord(time: t, text: w)) }
        }
        return words.isEmpty ? nil : words
    }
}
