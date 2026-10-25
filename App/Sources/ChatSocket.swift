import Foundation

/// The chat WebSocket (`wss://<site>/ws`, DE0CH/claudecodeui chat-websocket.service.ts): JSON frames, client→server
/// `type`, server→client `kind`. Reconnects 3 s after a drop, like the web UI.
@MainActor
final class ChatSocket: NSObject, URLSessionWebSocketDelegate {
    var onFrame: ((ServerMessage, JSONValue) -> Void)?
    var onState: ((Bool) -> Void)?
    var onUnauthorized: (() -> Void)?
    private(set) var connected = false
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let endpoint: Endpoint
    private var stopped = false
    private var generation = 0

    init(_ endpoint: Endpoint) { self.endpoint = endpoint }

    func connect() {
        stopped = false
        generation += 1
        let gen = generation
        var comps = URLComponents(url: endpoint.base, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        comps.path = "/ws"
        comps.query = nil
        var r = URLRequest(url: comps.url!)
        for (k, v) in endpoint.headers { r.setValue(v, forHTTPHeaderField: k) }
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: r)
        t.maximumMessageSize = 64 * 1024 * 1024
        task = t
        t.resume()
        receive(t, gen)
    }

    func disconnect() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    func send(_ obj: [String: Any]) {
        guard let t = task, let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
        t.send(.string(s)) { _ in }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor in self.setConnected(true) }
    }

    private func setConnected(_ c: Bool) {
        guard connected != c else { return }
        connected = c
        onState?(c)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    var data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let m = try? JSONDecoder().decode(ServerMessage.self, from: data),
                       let raw = try? JSONDecoder().decode(JSONValue.self, from: data) {
                        self.onFrame?(m, raw)
                    }
                    self.receive(t, gen)
                case .failure:
                    self.setConnected(false)
                    if let http = t.response as? HTTPURLResponse, http.statusCode == 401 || (300..<400).contains(http.statusCode) {
                        self.onUnauthorized?()
                        return
                    }
                    guard !self.stopped else { return }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !self.stopped && gen == self.generation { self.connect() }
                }
            }
        }
    }
}
