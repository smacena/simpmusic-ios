import Foundation

/// AutoEq headphone correction profiles (github.com/jaakkopasanen/AutoEq), the source SimpMusic
/// uses. Its "FixedBandEQ" results are generated at the same ten centres and Q (1.41) as this
/// equalizer, so a profile drops straight in. The index (~8.800 headphones) is cached on device.
enum AutoEq {
    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String // URL-encoded, relative to results/
        let source: String
        var id: String { path }
    }

    private static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results"

    private static var cacheFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("autoeq-index.md")
    }

    static func index() async throws -> [Entry] {
        var text: String?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7 * 86400 {
            text = try? String(contentsOf: cacheFile, encoding: .utf8)
        }
        if text == nil {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "\(base)/INDEX.md")!)
            try? data.write(to: cacheFile, options: .atomic)
            text = String(data: data, encoding: .utf8)
        }
        let regex = try NSRegularExpression(pattern: #"^- \[(.+)\]\(\./(.+)\) by (.+?)(?: on .+)?$"#, options: .anchorsMatchLines)
        let s = text ?? ""
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            guard let n = Range(m.range(at: 1), in: s), let p = Range(m.range(at: 2), in: s), let src = Range(m.range(at: 3), in: s) else { return nil }
            return Entry(name: String(s[n]), path: String(s[p]), source: String(s[src]))
        }
    }

    /// The ten gains (dB) and preamp of a profile.
    static func curve(_ entry: Entry) async throws -> (gains: [Double], preamp: Double) {
        let folder = entry.path.split(separator: "/").last.map(String.init) ?? entry.path
        let (data, _) = try await URLSession.shared.data(from: URL(string: "\(base)/\(entry.path)/\(folder)%20FixedBandEQ.txt")!)
        let text = String(data: data, encoding: .utf8) ?? ""
        var preamp = 0.0
        let centres: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        var gains = [Double](repeating: 0, count: 10)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if line.hasPrefix("Preamp:"), parts.count > 1 { preamp = Double(parts[1]) ?? 0; continue }
            guard let fc = parts.firstIndex(of: "Fc").flatMap({ Double(parts[$0 + 1]) }),
                  let gain = parts.firstIndex(of: "Gain").flatMap({ Double(parts[$0 + 1]) }) else { continue }
            // Matched by frequency (AutoEq writes 31.25 as "31").
            if let band = centres.indices.min(by: { abs(log2(centres[$0] / fc)) < abs(log2(centres[$1] / fc)) }) {
                gains[band] = min(max(gain, -12), 12)
            }
        }
        return (gains, min(max(preamp, -15), 15))
    }
}
