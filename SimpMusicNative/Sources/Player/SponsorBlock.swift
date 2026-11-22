import Foundation

/// SponsorBlock: community-marked segments (sponsor, self-promotion, intro/outro and the
/// non-music parts of music videos) skipped automatically. Public API, no account.
enum SponsorBlock {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "sponsorblock.enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "sponsorblock.enabled") }
    }

    static func segments(for videoId: String) async -> [ClosedRange<Double>] {
        guard enabled else { return [] }
        var comps = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        comps.queryItems = [
            URLQueryItem(name: "videoID", value: videoId),
            URLQueryItem(name: "categories", value: #"["sponsor","selfpromo","interaction","music_offtopic"]"#),
        ]
        guard let url = comps.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let seg = item["segment"] as? [Double], seg.count == 2, seg[1] > seg[0] + 0.5 else { return nil }
            return seg[0] ... seg[1]
        }
    }
}
