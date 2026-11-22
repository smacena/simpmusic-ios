import CommonCrypto
import Foundation
import Security

/// The signed-in YouTube session: the music.youtube.com cookies, kept in the Keychain (encrypted,
/// never in plain files). Requests to YouTube Music carry them plus the SAPISIDHASH header that
/// the web client sends, which personalises home, radio and the account's liked songs.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()
    @Published private(set) var isSignedIn = false

    private static let service = "org.simpmusic.native.youtube"
    nonisolated(unsafe) private static var cachedCookie: String? = Account.readKeychain()

    private init() { isSignedIn = Self.cachedCookie != nil }

    /// The cookie header, for Login Sync to hand to another device.
    nonisolated static var currentCookie: String? { cachedCookie }

    func signIn(cookieHeader: String) {
        Self.writeKeychain(cookieHeader)
        Self.cachedCookie = cookieHeader
        isSignedIn = true
    }

    func signOut() {
        Self.deleteKeychain()
        Self.cachedCookie = nil
        isSignedIn = false
        HTTPCookieStorage.shared.cookies?.filter { $0.domain.contains("youtube") || $0.domain.contains("google") }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    /// Headers for an authenticated YouTube Music request, or nil when signed out.
    nonisolated static func authHeaders() -> [String: String]? {
        guard let cookie = cachedCookie else { return nil }
        var headers = ["Cookie": cookie, "X-Goog-AuthUser": "0"]
        let parts = Dictionary(cookie.split(separator: ";").compactMap { pair -> (String, String)? in
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return kv.count == 2 ? (kv[0], kv[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
        if let sapisid = parts["SAPISID"] ?? parts["__Secure-3PAPISID"] {
            let ts = Int(Date().timeIntervalSince1970)
            headers["Authorization"] = "SAPISIDHASH \(ts)_\(sha1("\(ts) \(sapisid) https://music.youtube.com"))"
        }
        return headers
    }

    private nonisolated static func sha1(_ text: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let data = Array(text.utf8)
        CC_SHA1(data, CC_LONG(data.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Keychain

    private nonisolated static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "cookie"]
    }

    private nonisolated static func readKeychain() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func writeKeychain(_ value: String) {
        deleteKeychain()
        var q = query()
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    private nonisolated static func deleteKeychain() { SecItemDelete(query() as CFDictionary) }
}
