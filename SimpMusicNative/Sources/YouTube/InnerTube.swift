import Foundation

/// A song as the app shows and plays it.
struct Track: Identifiable, Hashable, Codable {
    let id: String // YouTube videoId
    let title: String
    let artist: String
    let thumbnail: URL?
    var durationText: String?
    /// YouTube's explicit badge, when the list showed it.
    var explicit: Bool? = nil
    /// MUSIC_VIDEO_TYPE_ATV (song) / OMV (official video) / UGC (user video) / …, when known.
    var videoType: String? = nil

    /// A video rather than a song (YouTube's own type; unknown counts as song, like the original).
    var isVideo: Bool { videoType.map { $0 != "MUSIC_VIDEO_TYPE_ATV" } ?? false }

    /// Hidden when the user turned explicit content off.
    var allowed: Bool { !(explicit == true && UserDefaults.standard.object(forKey: "content.explicit") as? Bool == false) }

    /// The largest square-ish artwork: YouTube Music thumbnails carry their size in the URL.
    var artworkLarge: URL? {
        guard let s = thumbnail?.absoluteString else { return nil }
        if let r = s.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return URL(string: s.replacingCharacters(in: r, with: "=w544-h544"))
        }
        return thumbnail
    }
}

/// A playable audio stream for one track.
struct AudioStream {
    let url: URL
    /// The real length. AVFoundation misreads YouTube's fragmented MP4 (about twice the length),
    /// so the `dur` parameter of the URL, or the player response, is the source of truth.
    let durationMs: Int
    /// YouTube's loudness relative to its reference level (positive = louder), for normalization.
    let loudnessDb: Double?
    /// When googlevideo stops honouring the URL (`expire` parameter, seconds since 1970).
    let expiresAt: Date?
}

enum InnerTubeError: Error {
    case http(Int)
    case unplayable(String)
    case noAudio
    case badResponse
}

/// The parts of YouTube Music's internal API ("InnerTube") the app needs, in Swift.
///
/// Values are the ones the SimpMusic project uses (core/service/kotlinYtmusicScraper):
/// search runs as the WEB_REMIX client (music.youtube.com), and audio comes from the VISIONOS
/// client, whose stream URLs carry no signature cipher and need no PoToken, so whole files play.
/// AAC (itag 140) is chosen because iOS does not decode Opus.
actor InnerTube {
    static let shared = InnerTube()

    struct Client {
        let name: String
        let version: String
        let headerName: Int
        let userAgent: String
        var deviceMake: String? = nil
        var deviceModel: String? = nil
        var osName: String? = nil
        var osVersion: String? = nil
    }

    static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

    static let webRemix = Client(name: "WEB_REMIX", version: "1.20260304.03.00", headerName: 1, userAgent: webUserAgent)

    static let visionOS = Client(
        name: "VISIONOS",
        version: "1.02",
        headerName: 101,
        userAgent: "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; US)",
        deviceMake: "Apple",
        deviceModel: "RealityDevice14,1",
        osName: "visionOS",
        osVersion: "25.6.0.23O471"
    )

    private let session: URLSession
    private var visitorData: String?
    private let hl: String
    private let gl: String

    init() {
        let config = Net.makeConfiguration() // carries Settings → Proxy
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
        // Settings → Conteúdo: country and language of YouTube Music's results (system by default).
        hl = UserDefaults.standard.string(forKey: "content.language").flatMap { $0.isEmpty ? nil : $0 } ?? Locale.current.language.languageCode?.identifier ?? "en"
        gl = UserDefaults.standard.string(forKey: "content.country").flatMap { $0.isEmpty ? nil : $0 } ?? Locale.current.region?.identifier ?? "US"
    }

    // MARK: Visitor id

    /// Signed out, YouTube answers these clients with LOGIN_REQUIRED unless a visitor id is sent.
    private func ensureVisitorData() async {
        if let v = visitorData, !v.isEmpty { return }
        if let saved = UserDefaults.standard.string(forKey: "visitorData"), !saved.isEmpty {
            visitorData = saved
            return
        }
        guard let url = URL(string: "https://music.youtube.com/sw.js_data") else { return }
        var request = URLRequest(url: url)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              var text = String(data: data, encoding: .utf8), text.count > 5 else { return }
        text.removeFirst(5) // ")]}'\n"
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let first = json.first as? [Any], first.count > 2,
              let values = first[2] as? [Any] else { return }
        let found = values.compactMap { $0 as? String }.first { $0.range(of: #"^Cg[stuv][A-Za-z0-9_-]{15,}"#, options: .regularExpression) != nil }
        if let found {
            visitorData = found
            UserDefaults.standard.set(found, forKey: "visitorData")
        }
    }

    // MARK: Requests

    private func context(_ client: Client) -> [String: Any] {
        var c: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": hl,
            "gl": gl,
            "userAgent": client.userAgent,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
        ]
        if let v = visitorData { c["visitorData"] = v }
        if let v = client.deviceMake { c["deviceMake"] = v }
        if let v = client.deviceModel { c["deviceModel"] = v }
        if let v = client.osName { c["osName"] = v }
        if let v = client.osVersion { c["osVersion"] = v }
        return ["client": c]
    }

    private func post(_ endpoint: String, client: Client, body: [String: Any]) async throws -> [String: Any] {
        await ensureVisitorData()
        guard let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false") else {
            throw InnerTubeError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var payload = body
        payload["context"] = context(client)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue("\(client.headerName)", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "x-origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        if let v = visitorData { request.setValue(v, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        // Signed in: YouTube Music requests carry the session (the stream client never does).
        if client.name == Self.webRemix.name, let auth = Account.authHeaders() {
            for (key, value) in auth { request.setValue(value, forHTTPHeaderField: key) }
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            AppLog.w("InnerTube", "\(endpoint) via \(client.name) answered HTTP \(status)")
            throw InnerTubeError.http(status)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.badResponse
        }
        return json
    }

    // MARK: Search

    /// Songs matching [query] (YouTube Music's "Songs" filter).
    func searchSongs(_ query: String) async throws -> [Track] {
        let json = try await post("search", client: Self.webRemix, body: [
            "query": query,
            "params": "EgWKAQIIAWoKEAkQBRAKEAMQBA==",
        ])
        return Self.parseListItems(json)
    }

    /// Every `musicResponsiveListItemRenderer` in a response, as tracks. Walking the tree instead
    /// of a fixed path keeps working when YouTube moves shelves around.
    static func parseListItems(_ root: Any) -> [Track] {
        var out: [Track] = []
        var seen = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any], let track = parseItem(item) {
                    if seen.insert(track.id).inserted { out.append(track) }
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return out.filter(\.allowed)
    }

    private static func runs(_ column: Any?) -> [[String: Any]] {
        let renderer = (column as? [String: Any])?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let text = renderer?["text"] as? [String: Any]
        return text?["runs"] as? [[String: Any]] ?? []
    }

    private static func parseItem(_ item: [String: Any]) -> Track? {
        let videoId =
            ((item["playlistItemData"] as? [String: Any])?["videoId"] as? String) ??
            findWatchVideoId(item["overlay"])
        guard let videoId, !videoId.isEmpty else { return nil }
        let columns = item["flexColumns"] as? [Any] ?? []
        let title = runs(columns.first).compactMap { $0["text"] as? String }.joined()
        guard !title.isEmpty else { return nil }
        let second = runs(columns.count > 1 ? columns[1] : nil).compactMap { $0["text"] as? String }.joined()
        let parts = second.components(separatedBy: " • ")
        let artist = parts.first ?? ""
        let duration = parts.last.flatMap { $0.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil ? $0 : nil }
        let thumbs =
            (((item["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
        return Track(id: videoId, title: title, artist: artist, thumbnail: thumb, durationText: duration,
                     explicit: hasExplicitBadge(item), videoType: findString("musicVideoType", in: item))
    }

    static func hasExplicitBadge(_ node: Any?) -> Bool {
        if let dict = node as? [String: Any] {
            if let icon = (dict["icon"] as? [String: Any])?["iconType"] as? String, icon == "MUSIC_EXPLICIT_BADGE" { return true }
            return dict.values.contains { hasExplicitBadge($0) }
        } else if let array = node as? [Any] {
            return array.contains { hasExplicitBadge($0) }
        }
        return false
    }

    static func findString(_ key: String, in node: Any?) -> String? {
        if let dict = node as? [String: Any] {
            if let v = dict[key] as? String { return v }
            for value in dict.values { if let v = findString(key, in: value) { return v } }
        } else if let array = node as? [Any] {
            for value in array { if let v = findString(key, in: value) { return v } }
        }
        return nil
    }

    private static func findWatchVideoId(_ node: Any?) -> String? {
        if let dict = node as? [String: Any] {
            if let watch = dict["watchEndpoint"] as? [String: Any], let id = watch["videoId"] as? String { return id }
            for value in dict.values { if let id = findWatchVideoId(value) { return id } }
        } else if let array = node as? [Any] {
            for value in array { if let id = findWatchVideoId(value) { return id } }
        }
        return nil
    }

    // MARK: Home and collections

    struct Shelf: Identifiable {
        let id = UUID()
        var strapline: String = ""
        let title: String
        let items: [ShelfItem]
        /// The shelf's "More" button (HomeItem.MoreEndpoint): where it leads and YouTube's page type.
        var more: MoreEndpoint? = nil
    }

    /// Where a section's "More" button leads. [pageType] is YouTube's `MUSIC_PAGE_TYPE_*`, so routing
    /// follows it; `FEmusic_*` pages carry none and open the generic Browse page.
    struct MoreEndpoint: Hashable {
        let browseId: String
        let params: String?
        let pageType: String?
    }

    enum ShelfItem: Identifiable {
        case song(Track)
        case collection(Collection)
        var id: String {
            switch self {
            case let .song(t): "s" + t.id
            case let .collection(c): "c" + c.browseId
            }
        }
    }

    struct Collection: Hashable {
        let browseId: String
        let title: String
        let subtitle: String
        let thumbnail: URL?
    }

    /// YouTube Music's home feed: carousels of songs, playlists and albums.
    func home() async throws -> [Shelf] { try await shelves(browseId: "FEmusic_home") }

    /// Top songs / videos / artists by country (YouTube Music's Charts page).
    func charts() async throws -> [Shelf] { try await shelves(browseId: "FEmusic_charts") }

    /// Autocomplete for the search box.
    func searchSuggestions(_ input: String) async -> [String] {
        guard let json = try? await post("music/get_search_suggestions", client: Self.webRemix, body: ["input": input]) else { return [] }
        var out: [String] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let r = dict["searchSuggestionRenderer"] as? [String: Any],
                   let runs = (r["suggestion"] as? [String: Any])?["runs"] as? [[String: Any]] {
                    out.append(runs.compactMap { $0["text"] as? String }.joined()); return
                }
                for v in dict.values { walk(v) }
            } else if let a = node as? [Any] { for v in a { walk(v) } }
        }
        walk(json)
        return out
    }

    func shelves(browseId: String) async throws -> [Shelf] {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": browseId])
        var shelves: [Shelf] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let shelf = dict["musicCarouselShelfRenderer"] as? [String: Any] {
                    if let parsed = Self.parseShelf(shelf) { shelves.append(parsed) }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)
        return shelves
    }

    private static func text(_ node: Any?) -> String {
        ((node as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private static func parseShelf(_ shelf: [String: Any]) -> Shelf? {
        let header = (shelf["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        let title = text(header?["title"])
        var items: [ShelfItem] = []
        for content in shelf["contents"] as? [[String: Any]] ?? [] {
            if let row = content["musicResponsiveListItemRenderer"] as? [String: Any], let track = parseItem(row) {
                items.append(.song(track))
            } else if let two = content["musicTwoRowItemRenderer"] as? [String: Any] {
                let thumbs = (((two["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
                let name = text(two["title"])
                let subtitle = text(two["subtitle"])
                let nav = two["navigationEndpoint"] as? [String: Any]
                if let browse = (nav?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
                    items.append(.collection(Collection(browseId: browse, title: name, subtitle: subtitle, thumbnail: thumb)))
                } else if let watch = nav?["watchEndpoint"] as? [String: Any], let id = watch["videoId"] as? String {
                    items.append(.song(Track(id: id, title: name, artist: subtitle.components(separatedBy: " • ").first ?? subtitle, thumbnail: thumb, durationText: nil)))
                }
            }
        }
        let strapline = text(header?["strapline"])
        let moreEndpoint = (((header?["moreContentButton"] as? [String: Any])?["buttonRenderer"] as? [String: Any])?["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
        var more: MoreEndpoint?
        // FEmusic_new_releases_albums has answered 4xx for every client since 2026-09 (HomeParser
        // drops it the same way), so its More would only open an error.
        if let e = moreEndpoint, let id = e["browseId"] as? String, id != "FEmusic_new_releases_albums" {
            more = MoreEndpoint(browseId: id, params: e["params"] as? String, pageType: findString("pageType", in: e))
        }
        return title.isEmpty || items.isEmpty ? nil : Shelf(strapline: strapline, title: title, items: items, more: more)
    }

    // MARK: Browse (a section's "More" page)

    struct Mood: Identifiable, Hashable {
        var id: String { params + title }
        let title: String
        let params: String
        /// `solid.leftStripeColor`, full ARGB straight from the API.
        let stripeColor: UInt32
    }

    struct BrowseCard: Identifiable {
        let item: ShelfItem
        /// Home's card shape: 16:9 for a video that plays in place, square for anything that opens a page.
        let aspectRatio: CGFloat
        var id: String { item.id }
    }

    struct BrowsePage {
        let title: String?
        let contents: [BrowseCard]
        let moods: [Mood]
    }

    /// HomeRepository.getBrowsePage: every grid / carousel / music shelf / playlist shelf of the page
    /// flattened into one de-duplicated list (no section titles), plus its mood & genre buttons.
    func browsePage(browseId: String, params: String?) async throws -> BrowsePage {
        var body: [String: Any] = ["browseId": browseId]
        if let params, !params.isEmpty { body["params"] = params }
        let json = try await post("browse", client: Self.webRemix, body: body)
        let title = Self.text(((json["header"] as? [String: Any])?["musicHeaderRenderer"] as? [String: Any])?["title"])
        var cards: [BrowseCard] = []
        var seen = Set<String>()
        var moods: [Mood] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let b = dict["musicNavigationButtonRenderer"] as? [String: Any] {
                    let endpoint = (b["clickCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any]
                    let stripe = ((b["solid"] as? [String: Any])?["leftStripeColor"] as? NSNumber)?.uint32Value ?? 0xFF808080
                    moods.append(Mood(title: Self.text(b["buttonText"]), params: endpoint?["params"] as? String ?? "", stripeColor: stripe))
                    return
                }
                if let card = Self.parseBrowseCard(dict) {
                    if seen.insert(card.id).inserted { cards.append(card) }
                    return
                }
                for (key, value) in dict where key != "header" { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json["contents"] as Any)
        if cards.isEmpty && moods.isEmpty { AppLog.w("InnerTube", "browse \(browseId) came back empty") }
        return BrowsePage(title: title.isEmpty ? nil : title, contents: cards, moods: moods)
    }

    /// MoodScreen's data (`FEmusic_moods_and_genres_category` + the button's params): the header and
    /// each section — carousel or grid — as a titled shelf.
    func moodPage(params: String) async throws -> (title: String, shelves: [Shelf]) {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": "FEmusic_moods_and_genres_category", "params": params])
        let title = Self.text(((json["header"] as? [String: Any])?["musicHeaderRenderer"] as? [String: Any])?["title"])
        var shelves: [Shelf] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let shelf = dict["musicCarouselShelfRenderer"] as? [String: Any] {
                    if let parsed = Self.parseShelf(shelf) { shelves.append(parsed) }
                    return
                }
                if let grid = dict["gridRenderer"] as? [String: Any] {
                    let gridTitle = Self.text(((grid["header"] as? [String: Any])?["gridHeaderRenderer"] as? [String: Any])?["title"])
                    let wrapped: [String: Any] = ["contents": grid["items"] ?? [], "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": gridTitle.isEmpty ? title : gridTitle]]]]]]
                    if let parsed = Self.parseShelf(wrapped) { shelves.append(parsed) }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json["contents"] as Any)
        return (title, shelves)
    }

    private static func thumbs(_ node: Any?) -> [[String: Any]] {
        (((node as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
    }

    /// Content.homeCardAspectRatio(): wide when the item plays in place and its thumbnail isn't square.
    private static func ratio(_ thumbs: [[String: Any]], opensPage: Bool) -> CGFloat {
        guard !opensPage, let first = thumbs.first else { return 1 }
        let w = (first["width"] as? NSNumber)?.intValue, h = (first["height"] as? NSNumber)?.intValue
        return w != h ? 16.0 / 9.0 : 1
    }

    private static func parseBrowseCard(_ dict: [String: Any]) -> BrowseCard? {
        if let row = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
            guard let track = parseItem(row) else { return nil }
            return BrowseCard(item: .song(track), aspectRatio: ratio(thumbs(row["thumbnail"]), opensPage: false))
        }
        if let two = dict["musicTwoRowItemRenderer"] as? [String: Any] {
            let t = thumbs(two["thumbnailRenderer"])
            let thumb = (t.last?["url"] as? String).flatMap(URL.init(string:))
            let name = text(two["title"]), subtitle = text(two["subtitle"])
            let nav = two["navigationEndpoint"] as? [String: Any]
            if let browse = (nav?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
                return BrowseCard(item: .collection(Collection(browseId: browse, title: name, subtitle: subtitle, thumbnail: thumb)), aspectRatio: 1)
            }
            if let id = (nav?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
                let track = Track(id: id, title: name, artist: subtitle.components(separatedBy: " • ").first ?? subtitle, thumbnail: thumb, durationText: nil,
                                  explicit: hasExplicitBadge(two), videoType: findString("musicVideoType", in: two))
                return BrowseCard(item: .song(track), aspectRatio: ratio(t, opensPage: false))
            }
            return nil
        }
        if let ep = dict["musicMultiRowListItemRenderer"] as? [String: Any] {
            // A podcast episode.
            guard let id = findWatchVideoId(ep["onTap"]) ?? findWatchVideoId(ep) else { return nil }
            let t = thumbs(ep["thumbnail"])
            let thumb = (t.last?["url"] as? String).flatMap(URL.init(string:))
            let track = Track(id: id, title: text(ep["title"]), artist: text(ep["subtitle"]), thumbnail: thumb, durationText: nil)
            return BrowseCard(item: .song(track), aspectRatio: ratio(t, opensPage: false))
        }
        return nil
    }

    /// "Moods & genres": each category becomes a shelf of the playlists it opens.
    func moodsAndGenres() async throws -> [Shelf] {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": "FEmusic_moods_and_genres"])
        var buttons: [(String, String, String)] = [] // title, browseId, params
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let b = dict["musicNavigationButtonRenderer"] as? [String: Any],
                   let endpoint = (b["clickCommand"] as? [String: Any])?["browseEndpoint"] as? [String: Any],
                   let id = endpoint["browseId"] as? String {
                    buttons.append((Self.text(b["buttonText"]), id, endpoint["params"] as? String ?? ""))
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)
        var shelves: [Shelf] = []
        for (title, id, params) in buttons.prefix(8) {
            var body: [String: Any] = ["browseId": id]
            if !params.isEmpty { body["params"] = params }
            guard let page = try? await post("browse", client: Self.webRemix, body: body) else { continue }
            var items: [ShelfItem] = []
            func collect(_ node: Any) {
                if let dict = node as? [String: Any] {
                    if let shelf = dict["musicCarouselShelfRenderer"] as? [String: Any], let parsed = Self.parseShelf(shelf) { items.append(contentsOf: parsed.items); return }
                    if let grid = dict["gridRenderer"] as? [String: Any], let parsed = Self.parseShelf(["contents": grid["items"] ?? [], "header": ["musicCarouselShelfBasicHeaderRenderer": ["title": ["runs": [["text": title]]]]]]) { items.append(contentsOf: parsed.items); return }
                    for value in dict.values { collect(value) }
                } else if let array = node as? [Any] {
                    for value in array { collect(value) }
                }
            }
            collect(page)
            if !items.isEmpty { shelves.append(Shelf(strapline: "Mood", title: title, items: Array(items.prefix(20)))) }
        }
        return shelves
    }

    /// The signed-in account's playlists on YouTube Music.
    func accountPlaylists() async throws -> [Collection] {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": "FEmusic_liked_playlists"])
        var out: [Collection] = []
        var seen = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let two = dict["musicTwoRowItemRenderer"] as? [String: Any],
                   let id = ((two["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
                   id.hasPrefix("VL"), seen.insert(id).inserted {
                    let thumbs = (((two["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                    out.append(Collection(browseId: id, title: Self.text(two["title"]), subtitle: Self.text(two["subtitle"]),
                                          thumbnail: (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))))
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)
        return out
    }

    /// The songs of a playlist or album page.
    func collectionTracks(_ browseId: String) async throws -> [Track] {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": browseId])
        var tracks = Self.parseListItems(json)
        // Album rows carry no artwork of their own: use the album cover.
        if tracks.contains(where: { $0.thumbnail == nil }), let cover = Self.firstThumbnail(json) {
            tracks = tracks.map { $0.thumbnail == nil ? Track(id: $0.id, title: $0.title, artist: $0.artist, thumbnail: cover, durationText: $0.durationText) : $0 }
        }
        return tracks
    }

    private static func firstThumbnail(_ node: Any) -> URL? {
        if let dict = node as? [String: Any] {
            if let thumbs = (dict["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]], let url = thumbs.last?["url"] as? String {
                return URL(string: url)
            }
            for value in dict.values { if let u = firstThumbnail(value) { return u } }
        } else if let array = node as? [Any] {
            for value in array { if let u = firstThumbnail(value) { return u } }
        }
        return nil
    }

    // MARK: Search for albums, artists, playlists

    enum CollectionKind: String, CaseIterable {
        case albums, artists, playlists
        var params: String {
            switch self {
            case .albums: "EgWKAQIYAWoKEAkQChAFEAMQBA=="
            case .artists: "EgWKAQIgAWoKEAkQChAFEAMQBA=="
            case .playlists: "EgeKAQQoAEABagoQAxAEEAoQCRAF"
            }
        }
    }

    func searchCollections(_ query: String, kind: CollectionKind) async throws -> [Collection] {
        let json = try await post("search", client: Self.webRemix, body: ["query": query, "params": kind.params])
        var out: [Collection] = []
        var seen = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let item = dict["musicResponsiveListItemRenderer"] as? [String: Any],
                   let browse = ((item["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
                   seen.insert(browse).inserted {
                    let columns = item["flexColumns"] as? [Any] ?? []
                    let title = Self.runs(columns.first).compactMap { $0["text"] as? String }.joined()
                    let subtitle = Self.runs(columns.count > 1 ? columns[1] : nil).compactMap { $0["text"] as? String }.joined()
                    let thumbs = (((item["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                    let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
                    if !title.isEmpty { out.append(Collection(browseId: browse, title: title, subtitle: subtitle, thumbnail: thumb)) }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)
        return out
    }

    // MARK: Artist page

    struct ArtistPage {
        let name: String
        let thumbnail: URL?
        let songs: [Track]
        let shelves: [Shelf]
    }

    /// An artist's channel: top songs plus carousels (albums, singles, videos, similar artists).
    func artist(_ browseId: String) async throws -> ArtistPage {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": browseId])
        let header = ((json["header"] as? [String: Any])?["musicImmersiveHeaderRenderer"] as? [String: Any]) ??
            ((json["header"] as? [String: Any])?["musicVisualHeaderRenderer"] as? [String: Any])
        let name = Self.text(header?["title"])
        let thumbs = (((header?["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
        var songs: [Track] = []
        var shelves: [Shelf] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let shelf = dict["musicShelfRenderer"] as? [String: Any] {
                    songs.append(contentsOf: Self.parseListItems(shelf))
                    return
                }
                if let carousel = dict["musicCarouselShelfRenderer"] as? [String: Any] {
                    if let parsed = Self.parseShelf(carousel) { shelves.append(parsed) }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json["contents"] as Any)
        return ArtistPage(name: name, thumbnail: thumb, songs: songs, shelves: shelves)
    }

    /// MoreAlbumsScreen's data: every album (or single/EP) of an artist — `MPAD<channel>` with the
    /// shelf's params — and the page title (the artist name).
    func discography(browseId: String, params: String) async throws -> (title: String, items: [Collection]) {
        let json = try await post("browse", client: Self.webRemix, body: ["browseId": browseId, "params": params])
        let title = Self.text(((json["header"] as? [String: Any])?["musicHeaderRenderer"] as? [String: Any])?["title"])
        var items: [Collection] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let two = dict["musicTwoRowItemRenderer"] as? [String: Any] {
                    let thumbs = (((two["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                    let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
                    if let id = ((two["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String {
                        items.append(Collection(browseId: id, title: Self.text(two["title"]), subtitle: Self.text(two["subtitle"]), thumbnail: thumb))
                    }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json["contents"] as Any)
        if items.isEmpty { AppLog.w("InnerTube", "discography \(browseId) came back empty") }
        return (title, items)
    }

    // MARK: Lyrics tab

    /// The plain lyrics YouTube Music shows in its "Lyrics" tab (next → MPLY browse id → browse).
    func youtubeLyrics(for videoId: String) async -> String? {
        guard let next = try? await post("next", client: Self.webRemix, body: ["videoId": videoId]) else { return nil }
        var browseId: String?
        func findTab(_ node: Any) {
            guard browseId == nil else { return }
            if let dict = node as? [String: Any] {
                if let id = dict["browseId"] as? String, id.hasPrefix("MPLY") { browseId = id; return }
                for v in dict.values { findTab(v) }
            } else if let a = node as? [Any] { for v in a { findTab(v) } }
        }
        findTab(next)
        guard let browseId, let page = try? await post("browse", client: Self.webRemix, body: ["browseId": browseId]) else { return nil }
        var text: String?
        func findShelf(_ node: Any) {
            guard text == nil else { return }
            if let dict = node as? [String: Any] {
                if let shelf = dict["musicDescriptionShelfRenderer"] as? [String: Any],
                   let runs = (shelf["description"] as? [String: Any])?["runs"] as? [[String: Any]] {
                    text = runs.compactMap { $0["text"] as? String }.joined(); return
                }
                for v in dict.values { findShelf(v) }
            } else if let a = node as? [Any] { for v in a { findShelf(v) } }
        }
        findShelf(page)
        return text?.isEmpty == false ? text : nil
    }

    // MARK: Radio (what plays after a song)

    /// The radio queue YouTube Music builds from a song ("next" endpoint, RDAMVM playlist).
    func radio(for videoId: String) async throws -> [Track] {
        let json = try await post("next", client: Self.webRemix, body: [
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "isAudioOnly": true,
            "params": "wAEB",
        ])
        var out: [Track] = []
        var seen = Set<String>()
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                let renderer =
                    (dict["playlistPanelVideoRenderer"] as? [String: Any]) ??
                    ((dict["playlistPanelVideoWrapperRenderer"] as? [String: Any])?["primaryRenderer"] as? [String: Any])?["playlistPanelVideoRenderer"] as? [String: Any]
                if let r = renderer, let id = r["videoId"] as? String, seen.insert(id).inserted {
                    let title = ((r["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                    let byline = ((r["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
                    let thumbs = ((r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]])
                    let thumb = (thumbs?.last?["url"] as? String).flatMap(URL.init(string:))
                    let length = ((r["lengthText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String
                    if !title.isEmpty {
                        out.append(Track(id: id, title: title, artist: byline.components(separatedBy: " • ").first ?? byline, thumbnail: thumb, durationText: length,
                                         explicit: Self.hasExplicitBadge(r["badges"]), videoType: Self.findString("musicVideoType", in: r)))
                    }
                    return
                }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(json)
        // Settings: explicit filter, and "rádio só áudio" (videos out, unless that empties the page).
        var result = out.filter(\.allowed)
        if UserDefaults.standard.bool(forKey: "radio.audioOnly") {
            let songs = result.filter { !$0.isVideo }
            if !songs.isEmpty { result = songs }
        }
        return result
    }

    // MARK: Video stream

    /// The best H.264 video-only stream up to 720p (iOS plays AVC everywhere; VP9/AV1 vary).
    func videoStream(for videoId: String) async throws -> URL {
        let json = try await post("player", client: Self.visionOS, body: [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": 20073]],
        ])
        guard (json["playabilityStatus"] as? [String: Any])?["status"] as? String == "OK" else { throw InnerTubeError.unplayable("video") }
        let formats = ((json["streamingData"] as? [String: Any])?["adaptiveFormats"] as? [[String: Any]]) ?? []
        let avc = formats.filter { ($0["mimeType"] as? String)?.hasPrefix("video/mp4; codecs=\"avc1") == true && $0["url"] != nil }
        let maxHeight = UserDefaults.standard.integer(forKey: "quality.video").nonZero ?? 720
        let pick = avc.filter { ($0["height"] as? Int ?? 0) <= maxHeight }.max { ($0["height"] as? Int ?? 0) < ($1["height"] as? Int ?? 0) } ?? avc.first
        guard let s = pick?["url"] as? String, let url = URL(string: s) else { throw InnerTubeError.noAudio }
        return url
    }

    // MARK: Audio stream

    /// The AAC stream of [videoId] from the VISIONOS client.
    func audioStream(for videoId: String, forDownload: Bool = false) async throws -> AudioStream {
        let json = try await post("player", client: Self.visionOS, body: [
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
            "playbackContext": ["contentPlaybackContext": ["signatureTimestamp": 20073]],
        ])
        let playability = json["playabilityStatus"] as? [String: Any]
        let status = playability?["status"] as? String ?? "?"
        guard status == "OK" else {
            if status == "LOGIN_REQUIRED" {
                // A stale visitor id is the usual cause; fetch a new one next time.
                visitorData = nil
                UserDefaults.standard.removeObject(forKey: "visitorData")
            }
            AppLog.w("InnerTube", "\(videoId) unplayable: \(status)")
            throw InnerTubeError.unplayable(status)
        }
        let streaming = json["streamingData"] as? [String: Any] ?? [:]
        let formats = (streaming["adaptiveFormats"] as? [[String: Any]] ?? []) + (streaming["formats"] as? [[String: Any]] ?? [])
        func audio(_ itag: Int) -> [String: Any]? { formats.first { ($0["itag"] as? Int) == itag && $0["url"] != nil } }
        let saver = !forDownload && UserDefaults.standard.string(forKey: "quality.audio") == "low"
        guard let format = (saver ? audio(139) : nil) ?? audio(140) ?? audio(141) ?? formats.first(where: {
            ($0["mimeType"] as? String)?.hasPrefix("audio/mp4") == true && $0["url"] != nil
        }), let urlString = format["url"] as? String, let url = URL(string: urlString) else {
            throw InnerTubeError.noAudio
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var durationMs = Int((Double(query["dur"] ?? "") ?? 0) * 1000)
        if durationMs == 0, let approx = format["approxDurationMs"] as? String { durationMs = Int(approx) ?? 0 }
        if durationMs == 0, let seconds = (json["videoDetails"] as? [String: Any])?["lengthSeconds"] as? String {
            durationMs = (Int(seconds) ?? 0) * 1000
        }
        let loudness = format["loudnessDb"] as? Double
        let expires = Double(query["expire"] ?? "").map { Date(timeIntervalSince1970: $0) }
        return AudioStream(url: url, durationMs: durationMs, loudnessDb: loudness, expiresAt: expires)
    }
}


extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
