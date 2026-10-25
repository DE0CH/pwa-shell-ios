import Foundation

/// A server's REST API (DE0CH/claudecodeui in Jarvis mode, or Jarvis 4's router). Every call carries the endpoint's
/// Access headers (the CF_Authorization cookie, or a service token's); redirects are not followed, so an expired
/// token shows up as `signedOut`.
final class API: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case signedOut, http(Int, String), decode
        var errorDescription: String? {
            switch self {
            case .signedOut: return L("signin.expired")
            case .http(let code, let msg): return msg.isEmpty ? L("error.http", code) : msg
            case .decode: return L("error.generic")
            }
        }
    }

    let endpoint: Endpoint
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    init(_ endpoint: Endpoint) { self.endpoint = endpoint }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func request(_ path: String, method: String = "GET", json: Any? = nil) -> URLRequest {
        var r = URLRequest(url: endpoint.url(path))
        r.httpMethod = method
        for (k, v) in endpoint.headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    @discardableResult
    func send(_ r: URLRequest, allow404: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw Failure.decode }
        if http.statusCode == 401 || (300..<400).contains(http.statusCode) { throw Failure.signedOut }
        // Access answers a request it refused with its own HTML page, not the server's JSON
        if http.statusCode == 403, (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html") { throw Failure.signedOut }
        if http.statusCode == 404 && allow404 { return (data, http) }
        if !(200..<300).contains(http.statusCode) {
            let j = try? JSONDecoder().decode(JSONValue.self, from: data)
            let msg = j?["error"]?["message"]?.string ?? j?["error"]?.string ?? ""
            throw Failure.http(http.statusCode, msg)
        }
        return (data, http)
    }

    /// The JSON body, unwrapped from {"success":true,"data":…} when it has that envelope.
    func json(_ r: URLRequest, allow404: Bool = false) async throws -> JSONValue {
        let (data, http) = try await send(r, allow404: allow404)
        if http.statusCode == 404 { return .null }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw Failure.decode }
        if v["success"] != nil, let d = v["data"] { return d }
        return v
    }

    // MARK: conversations

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    func recent(offset: Int = 0) async throws -> (items: [Conversation], hasMore: Bool) {
        let v = try await json(request("/api/providers/sessions/recent?limit=40&offset=\(offset)"))
        let items = (v["conversations"]?.array ?? []).compactMap { c -> Conversation? in
            guard let id = c["sessionId"]?.string else { return nil }
            return Conversation(id: id, title: c["sessionTitle"]?.string ?? "", lastActivity: Self.date(c["lastActivity"]?.string))
        }
        return (items, v["hasMore"]?.bool ?? false)
    }

    /// Recently deleted (GET /api/providers/sessions/deleted), most recently deleted first.
    func deleted() async throws -> [Conversation] {
        let v = try await json(request("/api/providers/sessions/deleted"))
        return (v["sessions"]?.array ?? []).compactMap { c in
            guard let id = c["sessionId"]?.string else { return nil }
            return Conversation(id: id, title: c["sessionTitle"]?.string ?? "",
                                lastActivity: Self.date(c["deletedAt"]?.string ?? c["lastActivity"]?.string),
                                purgeAt: Self.date(c["purgeAt"]?.string))
        }
    }

    func create(initialMessage: String) async throws -> String {
        let v = try await json(request("/api/providers/sessions", method: "POST",
                                       json: ["provider": "claude", "projectPath": "/workspace", "initialMessage": initialMessage]))
        guard let id = v["sessionId"]?.string else { throw Failure.decode }
        return id
    }

    func messages(_ id: String, limit: Int = 200, offset: Int = 0) async throws -> (messages: [ServerMessage], hasMore: Bool) {
        let r = request("/api/providers/sessions/\(id)/messages?limit=\(limit)&offset=\(offset)")
        let (data, _) = try await send(r)
        struct Env: Decodable { struct D: Decodable { var messages: [ServerMessage]; var hasMore: Bool? }; var data: D }
        guard let env = try? JSONDecoder().decode(Env.self, from: data) else { throw Failure.decode }
        return (env.data.messages, env.data.hasMore ?? false)
    }

    /// Running conversations: id → last event sequence number.
    func running() async throws -> [String: Int] {
        let v = try await json(request("/api/providers/sessions/running"))
        var out: [String: Int] = [:]
        for s in v["sessions"]?.array ?? [] {
            if let id = s["sessionId"]?.string { out[id] = Int(s["lastSeq"]?.number ?? 0) }
        }
        return out
    }

    func rename(_ id: String, to title: String) async throws {
        try await send(request("/api/providers/sessions/\(id)", method: "PUT", json: ["summary": title]))
    }

    /// Delete: to Recently deleted (restorable); `permanently` removes it for good.
    func delete(_ id: String, permanently: Bool = false) async throws {
        try await send(request("/api/providers/sessions/\(id)" + (permanently ? "?force=true" : ""), method: "DELETE"))
    }

    func restore(_ id: String) async throws {
        try await send(request("/api/providers/sessions/\(id)/restore", method: "POST"))
    }

    func warm(_ id: String?) async {
        _ = try? await send(request("/api/jarvis/warm", method: "POST", json: id.map { ["sessionId": $0] } ?? [:]))
    }

    func firstName() async -> String? {
        (try? await json(request("/api/jarvis/me")))?["firstName"]?.string
    }

    // MARK: files

    struct WorkspaceFile: Identifiable, Hashable { var path: String; var size: Int?; var caption: String?; var sentAt: Date?
        var id: String { path }; var name: String { (path as NSString).lastPathComponent } }

    func files(_ id: String) async throws -> [WorkspaceFile] {
        let v = try await json(request("/api/jarvis/sessions/\(id)/files"), allow404: true)
        return (v["files"]?.array ?? []).compactMap { f in
            guard let p = f["path"]?.string else { return nil }
            return WorkspaceFile(path: p, size: f["size"]?.number.map(Int.init), caption: f["caption"]?.string,
                                 sentAt: Self.date(f["sentAt"]?.string))
        }
    }

    func rawPath(_ id: String, _ path: String, inline: Bool = false) -> String {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "path", value: path)] + (inline ? [URLQueryItem(name: "inline", value: "1")] : [])
        return "/api/jarvis/sessions/\(id)/files/raw?" + (c.percentEncodedQuery ?? "")
    }

    /// Downloads a file into a fresh temporary folder under its own name.
    func download(_ path: String, name: String) async throws -> URL {
        let (data, _) = try await send(request(path))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("files/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        try data.write(to: url)
        return url
    }

    func data(_ path: String) async throws -> Data { try await send(request(path)).0 }

    /// Uploads attachments (multipart field `files`); returns the descriptors chat.send takes.
    func upload(_ items: [PendingAttachment]) async throws -> [JSONValue] {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for a in items {
            let safe = a.name.replacingOccurrences(of: "\"", with: "_")
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(safe)\"\r\nContent-Type: \(a.mimeType)\r\n\r\n".data(using: .utf8)!)
            body.append(a.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        var r = request("/api/assets/files", method: "POST")
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let v = try await json(r)
        return v["attachments"]?.array ?? []
    }

    // MARK: shares

    struct Share: Identifiable, Hashable { var id: String; var url: URL; var createdAt: Date? }

    func shares(_ id: String) async throws -> [Share] {
        let v = try await json(request("/api/jarvis/sessions/\(id)/shares"))
        return (v["shares"]?.array ?? []).compactMap(share)
    }

    func createShare(_ id: String) async throws -> Share {
        guard let s = share(try await json(request("/api/jarvis/sessions/\(id)/shares", method: "POST", json: [:]))) else {
            throw Failure.decode
        }
        return s
    }

    func stopShare(_ shareId: String) async throws {
        try await send(request("/api/jarvis/shares/\(shareId)", method: "DELETE"))
    }

    func share(_ v: JSONValue) -> Share? {
        guard let id = v["id"]?.string, let u = v["url"]?.string else { return nil }
        return Share(id: id, url: endpoint.url(u), createdAt: Self.date(v["createdAt"]?.string))
    }
}
