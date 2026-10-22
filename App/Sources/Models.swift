import Foundation

/// Any JSON value (tool inputs and results are free-form).
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] } else { return nil } }
    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var number: Double? { if case .number(let n) = self { return n } else { return nil } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    /// A string as the server sent it, or compact JSON for anything else.
    var text: String {
        if case .string(let s) = self { return s }
        guard let d = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// A tool input that may arrive as its JSON text while it streams.
    var parsedObject: JSONValue {
        if case .string(let s) = self, let d = s.data(using: .utf8), let v = try? JSONDecoder().decode(JSONValue.self, from: d) { return v }
        return self
    }
}

/// One server message (live WebSocket frame or history row): DE0CH/claudecodeui server/shared/types.ts NormalizedMessage.
struct ServerMessage: Decodable, Identifiable {
    var id: String
    var kind: String
    var sessionId: String?
    var timestamp: String?
    var role: String?
    var content: JSONValue?
    var toolName: String?
    var toolInput: JSONValue?
    var toolId: String?
    var isError: Bool?
    var toolUseResult: JSONValue?
    var toolResult: JSONValue?
    var images: [JSONValue]?
    var files: [JSONValue]?
    var parentToolUseId: String?
    var jarvisSandbox: String?
    var text: String?
    var canInterrupt: Bool?
    var success: Bool?
    var aborted: Bool?
    var seq: Int?
    var isProcessing: Bool?
    var lastSeq: Int?
    var session: SessionInfo?
    var code: String?
    var error: String?
    var anchorId: String?
    var action: String?

    struct SessionInfo: Decodable { var id: String?; var summary: String?; var lastActivity: String? }

    enum CodingKeys: String, CodingKey {
        case id, kind, sessionId, timestamp, role, content, toolName, toolInput, toolId, isError, toolUseResult, toolResult,
             images, files, parentToolUseId, jarvisSandbox, text, canInterrupt, success, aborted, seq, isProcessing, lastSeq,
             session, code, error, anchorId, action
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        sessionId = try? c.decode(String.self, forKey: .sessionId)
        timestamp = try? c.decode(String.self, forKey: .timestamp)
        role = try? c.decode(String.self, forKey: .role)
        content = try? c.decode(JSONValue.self, forKey: .content)
        toolName = try? c.decode(String.self, forKey: .toolName)
        toolInput = try? c.decode(JSONValue.self, forKey: .toolInput)
        toolId = try? c.decode(String.self, forKey: .toolId)
        isError = try? c.decode(Bool.self, forKey: .isError)
        toolUseResult = try? c.decode(JSONValue.self, forKey: .toolUseResult)
        toolResult = try? c.decode(JSONValue.self, forKey: .toolResult)
        images = try? c.decode([JSONValue].self, forKey: .images)
        files = try? c.decode([JSONValue].self, forKey: .files)
        parentToolUseId = try? c.decode(String.self, forKey: .parentToolUseId)
        jarvisSandbox = try? c.decode(String.self, forKey: .jarvisSandbox)
        text = try? c.decode(String.self, forKey: .text)
        canInterrupt = try? c.decode(Bool.self, forKey: .canInterrupt)
        success = try? c.decode(Bool.self, forKey: .success)
        aborted = try? c.decode(Bool.self, forKey: .aborted)
        seq = try? c.decode(Int.self, forKey: .seq)
        isProcessing = try? c.decode(Bool.self, forKey: .isProcessing)
        lastSeq = try? c.decode(Int.self, forKey: .lastSeq)
        session = try? c.decode(SessionInfo.self, forKey: .session)
        code = try? c.decode(String.self, forKey: .code)
        error = try? c.decode(String.self, forKey: .error)
        anchorId = try? c.decode(String.self, forKey: .anchorId)
        action = try? c.decode(String.self, forKey: .action)
    }

    init(localUser text: String, images: [JSONValue] = [], files: [JSONValue] = []) {
        id = "local-" + UUID().uuidString
        kind = "text"; role = "user"; content = .string(text); self.images = images; self.files = files
        timestamp = ISO8601DateFormatter().string(from: Date())
    }
}

/// A conversation in the list.
struct Conversation: Identifiable, Hashable {
    var id: String
    var title: String
    var lastActivity: Date?
}

/// An attachment chosen in the composer, before sending.
struct PendingAttachment: Identifiable {
    let id = UUID()
    var name: String
    var data: Data
    var mimeType: String
    var thumbnail: Data?
}

/// A file Claude sent (SendUserFile), relative to the conversation's workspace.
struct SentFile: Identifiable, Hashable {
    var path: String
    var size: Int?
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// A row on screen.
enum ChatRow: Identifiable {
    case user(id: String, text: String, images: [String], files: [String])
    case assistant(id: String, markdown: String)
    case thinking(id: String, text: String)
    case tool(id: String, ToolCall)
    case toolGroup(id: String, name: String, calls: [ToolCall])
    case sentFiles(id: String, caption: String?, files: [SentFile], sending: Bool)
    case error(id: String, text: String)

    var id: String {
        switch self {
        case .user(let id, _, _, _), .assistant(let id, _), .thinking(let id, _), .tool(let id, _), .toolGroup(let id, _, _),
             .sentFiles(let id, _, _, _), .error(let id, _): return id
        }
    }
}

struct ToolCall: Identifiable, Hashable {
    var id: String
    var name: String
    var input: JSONValue?
    var result: String?
    var isError: Bool
    var toolUseResult: JSONValue?

    /// One line naming what the tool worked on (a path, a command, a query, a URL…).
    var summary: String {
        guard let o = input?.parsedObject else { return "" }
        for k in ["file_path", "path", "command", "pattern", "query", "url", "description", "prompt", "skill"] {
            if let s = o[k]?.string, !s.isEmpty { return s.replacingOccurrences(of: "\n", with: " ") }
        }
        return ""
    }
}

extension String {
    /// A path inside the conversation's /workspace, relative (as the files endpoints take it), or nil outside it.
    var workspaceRelative: String? {
        var p = self
        if p.hasPrefix("/workspace/") { p.removeFirst("/workspace/".count) } else if p.hasPrefix("/") { return nil }
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p.isEmpty || p.contains("../") ? nil : p
    }
}
