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
/// app also checks the state. The token then goes on every API and WebSocket call as `cf-access-token`.
@MainActor
final class SignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled, badCallback
        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .badCallback: return L("signin.failed")
            }
        }
    }

    private var session: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    func run() async throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let state = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var comps = URLComponents(url: Config.siteURL.appendingPathComponent(Config.signInPath), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "state", value: state)]
        let url = comps.url!
        let scheme = Config.signInScheme
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: Failure.cancelled)
                } else { cont.resume(throwing: error ?? Failure.badCallback) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            if !s.start() { cont.resume(throwing: Failure.badCallback) }
        }
        session = nil
        return try Self.token(from: callback, scheme: scheme, state: state)
    }

    nonisolated static func token(from url: URL, scheme: String, state: String) throws -> String {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host == "signed-in",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let fragment = comps.fragment
        else { throw Failure.badCallback }
        var f = URLComponents()
        f.percentEncodedQuery = fragment
        guard let token = f.queryItems?.first(where: { $0.name == "token" })?.value, token.split(separator: ".").count == 3
        else { throw Failure.badCallback }
        return token
    }
}

/// The Access token, kept in the Keychain (this device only).
enum TokenStore {
    private static let account = "access-token"

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ token: String) {
        SecItemDelete(base as CFDictionary)
        var q = base
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() { SecItemDelete(base as CFDictionary) }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Bundle.main.bundleIdentifier ?? "app",
         kSecAttrAccount as String: account]
    }

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
