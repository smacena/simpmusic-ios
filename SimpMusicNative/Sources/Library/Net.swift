import Foundation

/// The app's one URLSession, carrying Settings → Proxy when it is on (HTTP or SOCKS5, with an
/// optional login), like SimpMusic's proxy setting. AVPlayer streams through the system's network
/// settings and cannot be given an app-level proxy; everything else (YouTube Music data, lyrics,
/// downloads, artwork, SponsorBlock, AutoEq) goes through here.
enum Net {
    static var proxyConfig: [AnyHashable: Any]? {
        let d = UserDefaults.standard
        guard d.bool(forKey: "proxy.enabled"), let host = d.string(forKey: "proxy.host"), !host.isEmpty else { return nil }
        let port = d.integer(forKey: "proxy.port")
        var dict: [AnyHashable: Any]
        if d.string(forKey: "proxy.type") == "socks" {
            dict = [kCFStreamPropertySOCKSProxyHost as String: host, kCFStreamPropertySOCKSProxyPort as String: port]
            if let user = d.string(forKey: "proxy.user"), !user.isEmpty {
                dict[kCFStreamPropertySOCKSUser as String] = user
                dict[kCFStreamPropertySOCKSPassword as String] = d.string(forKey: "proxy.pass") ?? ""
            }
        } else {
            dict = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port, "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        }
        return dict
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = proxyConfig
        return config
    }

    /// Rebuilt when the proxy setting changes (Settings calls reset()).
    nonisolated(unsafe) private(set) static var session = URLSession(configuration: makeConfiguration())

    static func reset() { session = URLSession(configuration: makeConfiguration()) }
}
