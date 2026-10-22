import AuthenticationServices
import Foundation
import Sodium
import WebKit

/// Signs in to a Cloudflare Access application outside the web view and hands the session to it.
///
/// Identity providers such as Google refuse to sign in inside an embedded web view
/// (`disallowed_useragent`), so the login runs in `ASWebAuthenticationSession` (the system browser
/// sheet, which shares Safari's cookies). The tokens come back through Cloudflare's own transfer
/// service, the flow `cloudflared access login` uses
/// (github.com/cloudflare/cloudflared, token/transfer.go and token/encrypt.go):
///
/// 1. The app makes an ephemeral X25519 key pair; its public key (base64url) names the transfer.
/// 2. The sheet opens `https://<site>/cdn-cgi/access/cli?token=<pub>&aud=<aud>&redirect_url=…
///    &send_org_token=true&edge_token_transfer=true`. The person signs in and taps Approve.
/// 3. Meanwhile the app polls `https://login.cloudflareaccess.org/transfer/<pub>`. When the login is
///    approved it answers with `{"app_token","org_token"}` sealed with NaCl box to our key
///    (body = base64(nonce ‖ ciphertext), sender key in the `service-public-key` header).
/// 4. The app closes the sheet and puts both tokens into the web view's cookie store as
///    `CF_Authorization`: the app token on the site's host, the org token on the team domain.
///    When the app token expires, Access re-issues it silently from the org token, inside the web view.
@MainActor
final class AccessSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case notBehindAccess, cancelled, timedOut, badResponse
        var errorDescription: String? {
            switch self {
            case .notBehindAccess: return L("error.notBehindAccess")
            case .cancelled: return nil
            case .timedOut: return L("error.timedOut")
            case .badResponse: return L("error.badResponse")
            }
        }
    }

    struct Tokens: Decodable {
        let app_token: String
        let org_token: String
    }

    private var session: ASWebAuthenticationSession?
    private var pollTask: Task<Void, Never>?
    private var completion: ((Result<Tokens, Error>) -> Void)?
    private weak var anchorWindow: UIWindow?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchorWindow ?? ASPresentationAnchor()
    }

    func start(from window: UIWindow?, completion: @escaping (Result<Tokens, Error>) -> Void) {
        cancel()
        anchorWindow = window
        self.completion = completion
        Task {
            do {
                let aud = try await Self.discoverAudience(site: Config.siteURL)
                try self.begin(aud: aud)
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
        session?.cancel()
        session = nil
        completion = nil
    }

    private func finish(_ result: Result<Tokens, Error>) {
        guard let completion else { return }
        self.completion = nil
        pollTask?.cancel()
        pollTask = nil
        session?.cancel()
        session = nil
        completion(result)
    }

    private func begin(aud: String) throws {
        let sodium = Sodium()
        guard let keyPair = sodium.box.keyPair() else { throw SignInError.badResponse }
        // Go's base64.URLEncoding: URL alphabet, with padding.
        let pub = Data(keyPair.publicKey).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")

        var root = URLComponents(url: Config.siteURL, resolvingAgainstBaseURL: false)!
        root.path = "/"
        root.query = nil
        root.fragment = nil
        let redirect = root.url!.absoluteString + "?" + Self.formEncode([("aud", aud), ("token", pub)])
        let cliQuery = Self.formEncode([
            ("aud", aud), ("edge_token_transfer", "true"), ("redirect_url", redirect),
            ("send_org_token", "true"), ("token", pub),
        ])
        guard let loginURL = URL(string: root.url!.absoluteString + "cdn-cgi/access/cli?" + cliQuery) else {
            throw SignInError.badResponse
        }

        // The callback scheme is never reached: the sheet is closed by the app once the transfer
        // service hands over the tokens (or by the person, which cancels).
        let session = ASWebAuthenticationSession(url: loginURL, callbackURLScheme: "pwashell-signin") { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.completion != nil else { return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    self.finish(.failure(SignInError.cancelled))
                } else if let error {
                    self.finish(.failure(error))
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else { throw SignInError.badResponse }

        pollTask = Task { [weak self] in
            let result = await Self.pollTransfer(pub: pub, secretKey: keyPair.secretKey)
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
    }

    /// The Access application's audience tag, from the `kid` parameter of the login redirect
    /// that an unauthenticated request to the site gets.
    nonisolated static func discoverAudience(site: URL) async throws -> String {
        var request = URLRequest(url: site, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let comps = URLComponents(string: location),
              let host = comps.host?.lowercased(), Config.isAccessHost(host),
              let kid = comps.queryItems?.first(where: { $0.name == "kid" })?.value, !kid.isEmpty
        else { throw SignInError.notBehindAccess }
        return kid
    }

    nonisolated static func pollTransfer(pub: String, secretKey: Bytes) async -> Result<Tokens, Error> {
        guard let url = URL(string: "https://login.cloudflareaccess.org/transfer/" + pub) else {
            return .failure(SignInError.badResponse)
        }
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            if Task.isCancelled { return .failure(SignInError.cancelled) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("pwa-shell-ios", forHTTPHeaderField: "User-Agent")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let senderKey = http.value(forHTTPHeaderField: "service-public-key") {
                return decrypt(body: data, senderKey: senderKey, secretKey: secretKey)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return .failure(SignInError.timedOut)
    }

    nonisolated static func decrypt(body: Data, senderKey: String, secretKey: Bytes) -> Result<Tokens, Error> {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sealed = base64Decode(text), let sender = base64Decode(senderKey),
              let plain = Sodium().box.open(nonceAndAuthenticatedCipherText: Bytes(sealed),
                                            senderPublicKey: Bytes(sender), recipientSecretKey: secretKey),
              let tokens = try? JSONDecoder().decode(Tokens.self, from: Data(plain))
        else { return .failure(SignInError.badResponse) }
        return .success(tokens)
    }

    /// Standard or URL-alphabet base64, padded or not.
    nonisolated static func base64Decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// application/x-www-form-urlencoded, encoding everything but unreserved characters (URLComponents
    /// leaves `&`, `=` and `+` alone inside values, which would break the nested redirect_url).
    nonisolated static func formEncode(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return items.map { enc($0.0) + "=" + enc($0.1) }.joined(separator: "&")
    }

    /// Cookies that carry the session into the web view.
    nonisolated static func cookies(for tokens: Tokens, site: URL) -> [HTTPCookie] {
        var result: [HTTPCookie] = []
        if let host = site.host, let cookie = makeCookie(token: tokens.app_token, host: host) { result.append(cookie) }
        if let iss = jwtClaims(tokens.org_token)?["iss"] as? String, let host = URL(string: iss)?.host,
           Config.isAccessHost(host.lowercased()), let cookie = makeCookie(token: tokens.org_token, host: host) {
            result.append(cookie)
        }
        return result
    }

    nonisolated static func makeCookie(token: String, host: String) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: "CF_Authorization", .value: token, .domain: host, .path: "/", .secure: "TRUE",
            HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]
        if let exp = jwtClaims(token)?["exp"] as? Double { props[.expires] = Date(timeIntervalSince1970: exp) }
        return HTTPCookie(properties: props)
    }

    nonisolated static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2, let data = base64Decode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
