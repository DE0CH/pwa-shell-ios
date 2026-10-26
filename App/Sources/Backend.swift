import Foundation
import UIKit

/// A conversation's server: where it is and the headers that get a request past Cloudflare Access.
struct Endpoint: Equatable {
    var base: URL
    var headers: [String: String]

    func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }
}

/// What a backend offers besides chatting in an open conversation; the screens hide the rest.
struct Features {
    /// "New chat": a conversation started from the app
    var newChat = true
    /// rename, delete, Recently deleted
    var manage = true
    /// 分享: read-only links
    var share = true
    /// typing warms a sandbox host
    var warm = true
    /// a paused conversation can be resumed from the list
    var resume = false
}

/// The kind of server the app is a client of (build input PWA_BACKEND). Every screen is shared; a backend decides only
/// how the app signs in, where the conversation list comes from, and which server each conversation is on.
///   server   one CloudCLI-fork server (DE0CH/claudecodeui in Jarvis mode, e.g. YYC AI): its own conversation list,
///            Access sign-in through the server (ServerBackend)
///   jarvis4  Jarvis 4: each `cloudcli` session is a conversation on its own server, the session's origin; the app
///            pairs once with Jarvis 4 for an Access service token (Jarvis4Backend)
@MainActor
protocol Backend: AnyObject {
    var features: Features { get }
    /// The server keeps the list current with `session_upserted` / `session_removed` frames.
    var serverList: Bool { get }
    var signedIn: Bool { get }
    /// Credentials saved on this device, if still usable.
    func loadSaved() -> Bool
    func signIn() async throws
    func signOut()
    func list(offset: Int) async throws -> (items: [Conversation], hasMore: Bool)
    /// The server of a conversation in the list (nil: a new conversation).
    func endpoint(for conversation: Conversation?) -> Endpoint?
    /// The server's own id of a list item's conversation: the item itself, or (Jarvis 4) the session's main
    /// conversation, nil while the session has none.
    func chatId(for conversation: Conversation, api: API) async throws -> String?
    func resume(_ conversation: Conversation) async throws
}

enum Backends {
    @MainActor static func make() -> Backend {
        Config.backend == "jarvis4" ? Jarvis4Backend() : ServerBackend()
    }
}

/// A sign-in round trip in the system sheet (SignIn.callback) that didn't come back right.
enum WebAuth {
    enum Failure: LocalizedError {
        case cancelled, badCallback
        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .badCallback: return L("signin.failed")
            }
        }
    }
}

/// A random state for a sign-in round trip.
func randomState() -> String {
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

// MARK: - one CloudCLI-fork server

/// YYC AI's kind: one server behind Cloudflare Access, the caller's own Access token as the CF_Authorization cookie.
@MainActor
final class ServerBackend: Backend {
    let features = Features()
    let serverList = true
    private var token: String?
    private let signIn_ = SignIn()

    var signedIn: Bool { token != nil }

    func loadSaved() -> Bool {
        if let t = Config.testToken { token = t } else if let t = TokenStore.load(), (TokenStore.secondsLeft(t) ?? 1) > 60 { token = t }
        return token != nil
    }

    func signIn() async throws {
        let t = try await signIn_.run()
        TokenStore.save(t)
        token = t
    }

    func signOut() {
        TokenStore.clear()
        token = nil
    }

    private var endpoint: Endpoint? {
        token.map { Endpoint(base: Config.siteURL, headers: ["Cookie": "CF_Authorization=\($0)"]) }
    }

    func list(offset: Int) async throws -> (items: [Conversation], hasMore: Bool) {
        guard let endpoint else { throw API.Failure.signedOut }
        return try await API(endpoint).recent(offset: offset)
    }

    func endpoint(for conversation: Conversation?) -> Endpoint? { endpoint }

    func chatId(for conversation: Conversation, api: API) async throws -> String? { conversation.id }

    func resume(_ conversation: Conversation) async throws {}
}

// MARK: - Jarvis 4

/// Jarvis 4 (DE0CH/jarvis4): the app pairs once (`GET /api/devices/pair?app=jarvis4chat`, Deyao's Access login in the
/// system sheet; the answer `<bundle id>://paired?state&id&clientId&clientSecret` carries an Access service token for
/// this device), lists the `cloudcli` sessions (`GET /api/remotes?harness=cloudcli`) and talks to each session's own
/// CloudCLI server at `https://<session id>-s.deyaochen.com/` with the token's CF-Access-Client-Id/-Secret headers.
/// A session is one conversation (its main one, `GET /api/jarvis/main`); sessions start in the Jarvis 4 app.
@MainActor
final class Jarvis4Backend: Backend {
    let features = Features(newChat: false, manage: false, share: false, warm: false, resume: true)
    let serverList = false
    private var creds: DeviceCredentials?
    private let sheet = SignIn()

    var signedIn: Bool { creds != nil }

    func loadSaved() -> Bool {
        #if DEBUG
        if let t = Config.testToken {
            creds = DeviceCredentials(id: "test", clientId: "test-client", clientSecret: t)
            return true
        }
        #endif
        creds = DeviceCredentials.load()
        return creds != nil
    }

    func signIn() async throws {
        let state = randomState()
        var comps = URLComponents(url: Config.url("/api/devices/pair"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "name", value: UIDevice.current.name),
            URLQueryItem(name: "model", value: UIDevice.current.model),
            URLQueryItem(name: "app", value: "jarvis4chat"),
        ]
        let callback = try await sheet.callback(for: comps.url!, scheme: Config.signInScheme)
        var c = try DeviceCredentials.from(callback, scheme: Config.signInScheme, state: state)
        c.pairedAt = Date()
        c.save()
        creds = c
    }

    func signOut() {
        DeviceCredentials.clear()
        creds = nil
    }

    private var headers: [String: String] {
        guard let creds else { return [:] }
        return ["CF-Access-Client-Id": creds.clientId, "CF-Access-Client-Secret": creds.clientSecret]
    }

    func list(offset: Int) async throws -> (items: [Conversation], hasMore: Bool) {
        guard creds != nil else { throw API.Failure.signedOut }
        let api = API(Endpoint(base: Config.siteURL, headers: headers))
        let v = try await activated { try await api.json(api.request("/api/remotes?harness=cloudcli")) }
        let items = (v["sessions"]?.array ?? []).compactMap { s -> Conversation? in
            guard let id = s["id"]?.string else { return nil }
            var remote: URL?
            if let w = s["webUrl"]?.string, let u = URL(string: w), Self.isSessionOrigin(u) { remote = u }
            return Conversation(id: id, title: s["title"]?.string ?? "", lastActivity: nil,
                                state: s["state"]?.string, remote: remote ?? Self.origin(of: id))
        }
        return (items, false)
    }

    /// Cloudflare refuses a new service token for up to ~30 s after the router minted it, which looks like a sign-out:
    /// while the token is that fresh, wait and ask again instead of throwing it away.
    private func activated<T>(_ call: () async throws -> T) async throws -> T {
        while true {
            do { return try await call() } catch API.Failure.signedOut {
                guard let at = creds?.pairedAt, Date().timeIntervalSince(at) < 90 else { throw API.Failure.signedOut }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func endpoint(for conversation: Conversation?) -> Endpoint? {
        guard let c = conversation, let base = c.remote ?? Self.origin(of: c.id) else { return nil }
        return Endpoint(base: base, headers: headers)
    }

    func chatId(for conversation: Conversation, api: API) async throws -> String? {
        try await api.json(api.request("/api/jarvis/main"))["sessionId"]?.string
    }

    func resume(_ conversation: Conversation) async throws {
        let api = API(Endpoint(base: Config.siteURL, headers: headers))
        try await api.send(api.request("/api/sessions/\(conversation.id)/start", method: "POST", json: [:]))
    }

    /// A session's own origin. The service token's headers go only there and to Jarvis 4 itself.
    static func origin(of sessionId: String) -> URL? {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "PWASiteURLOverride") != nil { return Config.siteURL }
        #endif
        let label = sessionId.lowercased().map { ($0.isLetter || $0.isNumber) && $0.isASCII ? String($0) : "-" }.joined()
        return URL(string: "https://\(label)-s.deyaochen.com/")
    }

    static func isSessionOrigin(_ u: URL) -> Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "PWASiteURLOverride") != nil { return true }
        #endif
        return u.scheme == "https" && (u.host ?? "").hasSuffix("-s.deyaochen.com")
    }
}

/// This device's Access service token from Jarvis 4's pairing, kept in the Keychain (this device only).
struct DeviceCredentials: Codable {
    var id: String
    var clientId: String
    var clientSecret: String
    /// When this device paired (nil for a token saved before this field existed).
    var pairedAt: Date?

    static func from(_ url: URL, scheme: String, state: String) throws -> DeviceCredentials {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host == "paired",
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              q.first(where: { $0.name == "state" })?.value == state
        else { throw WebAuth.Failure.badCallback }
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        if let e = v("error") { throw API.Failure.http(Int(v("status") ?? "") ?? 400, e) }
        guard let id = v("id"), let cid = v("clientId"), let secret = v("clientSecret") else { throw WebAuth.Failure.badCallback }
        return DeviceCredentials(id: id, clientId: cid, clientSecret: secret)
    }

    private static let account = "device-token"

    static func load() -> DeviceCredentials? {
        Keychain.load(account).flatMap { try? JSONDecoder().decode(DeviceCredentials.self, from: $0) }
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { Keychain.save(Self.account, d) }
    }

    static func clear() { Keychain.clear(account) }
}
