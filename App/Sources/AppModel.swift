import Foundation
import Observation
import SwiftUI

/// The app's state. All logic stays on the server; this only holds what the screens show and relays actions.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case idle, preparing(Date), working(Date) }

    var token: String?
    var api: API?
    var conversations: [Conversation] = []
    var hasMore = false
    var deletedConversations: [Conversation] = []
    var running: Set<String> = []
    var selected: String?
    var messages: [ServerMessage] = []
    var rows: [ChatRow] { Transcript.rows(messages) }
    var olderAvailable = false
    var phase: Phase = .idle
    var connected = true
    var firstName: String?
    var nameLoaded = false
    var banner: String?
    var signingIn = false
    var signInError: String?
    var draft = ""
    var pending: [PendingAttachment] = []
    var sending = false
    var loadingHistory = false

    @ObservationIgnored private var socket: ChatSocket?
    @ObservationIgnored private var lastWarm: [String: Date] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let signIn = SignIn()

    init() {
        if let t = Config.testToken { token = t } else if let t = TokenStore.load(), (TokenStore.secondsLeft(t) ?? 1) > 60 { token = t }
        if token != nil { start() }
    }

    var title: String {
        guard let id = selected else { return L("chat.new") }
        return conversations.first { $0.id == id }?.title ?? ""
    }

    var isBusy: Bool { phase != .idle }

    /// The person has any conversation other than the open one (the greeting's "returning" phrases).
    var returning: Bool { conversations.contains { $0.id != selected } }

    // MARK: sign-in

    func startSignIn() {
        signingIn = true
        signInError = nil
        Task {
            defer { signingIn = false }
            do {
                let t = try await signIn.run()
                TokenStore.save(t)
                token = t
                start()
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription
            }
        }
    }

    func signedOut() {
        socket?.disconnect()
        socket = nil
        pollTask?.cancel()
        TokenStore.clear()
        token = nil
        api = nil
    }

    private func start() {
        guard let token else { return }
        let api = API(token: token)
        self.api = api
        let s = ChatSocket(token: token)
        s.onFrame = { [weak self] m, raw in self?.handle(m, raw) }
        s.onState = { [weak self] up in self?.socketState(up) }
        s.onUnauthorized = { [weak self] in self?.signedOut() }
        socket = s
        s.connect()
        Task { await loadList() }
        Task {
            firstName = await api.firstName()
            nameLoaded = true
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollRunning()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func guarded(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch API.Failure.signedOut { signedOut() } catch {
                banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    // MARK: conversation list

    func loadList() async {
        guard let api else { return }
        do {
            let r = try await api.recent()
            conversations = r.items
            hasMore = r.hasMore
        } catch API.Failure.signedOut { signedOut() } catch {}
    }

    func loadMore() {
        guard let api, hasMore else { return }
        guarded {
            let r = try await api.recent(offset: self.conversations.count)
            let known = Set(self.conversations.map(\.id))
            self.conversations += r.items.filter { !known.contains($0.id) }
            self.hasMore = r.hasMore
        }
    }

    func loadDeleted() {
        guard let api else { return }
        guarded { self.deletedConversations = try await api.deleted() }
    }

    private func pollRunning() async {
        guard let api else { return }
        if let r = try? await api.running() { running = Set(r.keys) }
    }

    func rename(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, !t.isEmpty else { return }
        guarded {
            try await api.rename(id, to: t)
            if let i = self.conversations.firstIndex(where: { $0.id == id }) { self.conversations[i].title = t }
        }
    }

    func delete(_ id: String) {
        guard let api else { return }
        guarded {
            try await api.delete(id)
            self.conversations.removeAll { $0.id == id }
            if self.selected == id { self.newChat() }
        }
    }

    func restore(_ id: String) {
        guard let api else { return }
        guarded {
            try await api.restore(id)
            self.deletedConversations.removeAll { $0.id == id }
            await self.loadList()
        }
    }

    func deletePermanently(_ id: String) {
        guard let api else { return }
        guarded {
            try await api.delete(id, permanently: true)
            self.deletedConversations.removeAll { $0.id == id }
        }
    }

    // MARK: a conversation

    func newChat() {
        selected = nil
        messages = []
        phase = .idle
        olderAvailable = false
    }

    func open(_ id: String) {
        guard selected != id else { return }
        selected = id
        messages = []
        phase = running.contains(id) ? .working(Date()) : .idle
        Task { await reload(subscribe: true) }
    }

    func reload(subscribe: Bool) async {
        guard let api, let id = selected else { return }
        loadingHistory = true
        defer { loadingHistory = false }
        do {
            let seqs = (try? await api.running()) ?? [:]
            let h = try await api.messages(id)
            guard selected == id else { return }
            let local = messages.filter { $0.id.hasPrefix("local-") }
            messages = h.messages + (h.messages.contains { $0.role == "user" } || local.isEmpty ? [] : local)
            olderAvailable = h.hasMore
            if subscribe {
                socket?.send(["type": "chat.subscribe", "sessions": [["sessionId": id, "lastSeq": seqs[id] ?? 0]]])
            }
        } catch API.Failure.signedOut { signedOut() } catch {
            banner = (error as? LocalizedError)?.errorDescription
        }
    }

    func loadOlder() {
        guard let api, let id = selected, olderAvailable else { return }
        guarded {
            let h = try await api.messages(id, offset: self.messages.filter { !$0.id.hasPrefix("local-") }.count)
            guard self.selected == id else { return }
            let known = Set(self.messages.map(\.id))
            self.messages = h.messages.filter { !known.contains($0.id) } + self.messages
            self.olderAvailable = h.hasMore
        }
    }

    func draftChanged() {
        guard let api, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let key = selected ?? "new"
        if let t = lastWarm[key], Date().timeIntervalSince(t) < 30 { return }
        lastWarm[key] = Date()
        let id = selected
        Task { await api.warm(id) }
    }

    var canSend: Bool {
        !sending && !isBusy && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    func send() {
        guard let api, canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pending
        sending = true
        guarded {
            defer { self.sending = false }
            let uploaded = attachments.isEmpty ? [] : try await api.upload(attachments)
            var id = self.selected
            if id == nil {
                let new = try await api.create(initialMessage: text)
                id = new
                self.selected = new
                if !self.conversations.contains(where: { $0.id == new }) {
                    self.conversations.insert(Conversation(id: new, title: String(text.prefix(24)), lastActivity: Date()), at: 0)
                }
            }
            guard let sid = id else { return }
            self.draft = ""
            self.pending = []
            let images = attachments.filter { $0.mimeType.hasPrefix("image/") }.compactMap { a -> JSONValue? in
                guard let t = a.thumbnail ?? (a.data.count < 4_000_000 ? a.data : nil) else { return nil }
                return .object(["data": .string("data:image/jpeg;base64," + t.base64EncodedString())])
            }
            let files = attachments.filter { !$0.mimeType.hasPrefix("image/") }.map { JSONValue.object(["name": .string($0.name)]) }
            self.messages.append(ServerMessage(localUser: text, images: images, files: files))
            self.phase = .working(Date())
            let opts: [String: Any] = [
                "permissionMode": "bypassPermissions",
                "toolsSettings": ["allowedTools": [], "disallowedTools": [], "skipPermissions": false],
                "skipPermissions": false,
                "sessionSummary": String(text.prefix(80)),
                "attachments": uploaded.compactMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
                "sentAt": ISO8601DateFormatter().string(from: Date()),
            ]
            self.socket?.send(["type": "chat.send", "sessionId": sid, "content": text, "options": opts])
        }
    }

    func stop() {
        guard let id = selected else { return }
        socket?.send(["type": "chat.abort", "sessionId": id])
    }

    // MARK: server frames

    private func socketState(_ up: Bool) {
        let was = connected
        connected = up
        if up && !was {
            Task {
                await loadList()
                await reload(subscribe: true)
            }
        }
    }

    private func handle(_ m: ServerMessage, _ raw: JSONValue) {
        switch m.kind {
        case "session_upserted":
            guard let id = m.sessionId else { return }
            let title = m.session?.summary ?? ""
            let when = API.date(m.session?.lastActivity) ?? Date()
            if let i = conversations.firstIndex(where: { $0.id == id }) {
                var c = conversations.remove(at: i)
                if !title.isEmpty { c.title = title }
                c.lastActivity = when
                conversations.insert(c, at: 0)
            } else {
                conversations.insert(Conversation(id: id, title: title, lastActivity: when), at: 0)
            }
            deletedConversations.removeAll { $0.id == id }
        case "session_removed":
            guard let id = m.sessionId else { return }
            conversations.removeAll { $0.id == id }
            if selected == id { newChat() }
        default:
            break
        }
        guard let sid = m.sessionId, sid == selected else { return }
        switch m.kind {
        case "chat_subscribed":
            if m.isProcessing == true { if phase == .idle { phase = .working(Date()) } } else if !sending { phase = .idle }
        case "status":
            if m.jarvisSandbox == "preparing", case .working = phase { phase = .preparing(Date()) }
            else if m.jarvisSandbox == "ready", case .preparing = phase { phase = .working(Date()) }
        case "complete":
            phase = .idle
            running.remove(sid)
            Task { await reload(subscribe: false) }
        case "protocol_error":
            phase = .idle
            var e = m
            e.kind = "error"
            e.content = .string(m.error ?? L("error.generic"))
            messages.append(e)
        case "history_truncated":
            Task { await reload(subscribe: false) }
        case "text", "thinking", "tool_use", "tool_result", "error":
            if !messages.contains(where: { $0.id == m.id }) { messages.append(m) }
        default:
            break
        }
    }

    // MARK: files

    func previewFile(path: String, name: String) async -> URL? {
        guard let api, let id = selected else { return nil }
        do { return try await api.download(api.rawPath(id, path), name: name) } catch API.Failure.signedOut { signedOut(); return nil } catch {
            banner = L("files.loadError")
            return nil
        }
    }
}
