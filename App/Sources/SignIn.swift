import AuthenticationServices
import Foundation
import Security
import UIKit

/// Signs in to the server behind Cloudflare Access.
///
/// The app opens `https://<site>/api/jarvis/app-signin?state=<random>` in ASWebAuthenticationSession (the system
/// sign-in sheet, which Google allows and which shares Safari's cookies). The person sees only Access's own login
/// (Google or an emailed code). After it, the server redirects to `<scheme>://signed-in?state=…#token=<JWT>`, with the
/// caller's own Access token. ASWebAuthenticationSession hands that callback only to the session that started it; the
/// app also checks the state. The token then goes on every API and WebSocket call as the CF_Authorization cookie.
/// Jarvis 4's pairing (Jarvis4Backend) uses the same sheet through `callback(for:scheme:)`.
@MainActor
final class SignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    func run() async throws -> String {
        let state = randomState()
        var comps = URLComponents(url: Config.siteURL.appendingPathComponent(Config.signInPath), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "state", value: state)]
        let scheme = Config.signInScheme
        let callback = try await callback(for: comps.url!, scheme: scheme)
        return try Self.token(from: callback, scheme: scheme, state: state)
    }

    /// Opens `url` in the system sign-in sheet; the callback to `scheme`.
    func callback(for url: URL, scheme: String) async throws -> URL {
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: WebAuth.Failure.cancelled)
                } else { cont.resume(throwing: error ?? WebAuth.Failure.badCallback) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            if !s.start() { cont.resume(throwing: WebAuth.Failure.badCallback) }
        }
        session = nil
        return callback
    }

    nonisolated static func token(from url: URL, scheme: String, state: String) throws -> String {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host == "signed-in",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let fragment = comps.fragment
        else { throw WebAuth.Failure.badCallback }
        var f = URLComponents()
        f.percentEncodedQuery = fragment
        guard let token = f.queryItems?.first(where: { $0.name == "token" })?.value, token.split(separator: ".").count == 3
        else { throw WebAuth.Failure.badCallback }
        return token
    }
}

/// Generic-password items of this app in the Keychain (this device only).
enum Keychain {
    static func load(_ account: String) -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func save(_ account: String, _ data: Data) {
        SecItemDelete(base(account) as CFDictionary)
        var q = base(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear(_ account: String) { SecItemDelete(base(account) as CFDictionary) }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Bundle.main.bundleIdentifier ?? "app",
         kSecAttrAccount as String: account]
    }
}

/// The Access token, kept in the Keychain (this device only).
enum TokenStore {
    private static let account = "access-token"

    static func load() -> String? { Keychain.load(account).flatMap { String(data: $0, encoding: .utf8) } }
    static func save(_ token: String) { Keychain.save(account, Data(token.utf8)) }
    static func clear() { Keychain.clear(account) }

    /// Seconds until the token's `exp`, or nil when unreadable.
    static func secondsLeft(_ token: String) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let exp = j["exp"] as? Double else { return nil }
        return exp - Date().timeIntervalSince1970
    }
}
