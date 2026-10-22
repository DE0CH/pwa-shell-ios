import Foundation

/// Turns server messages into rows the way the web UI does (DE0CH/claudecodeui useChatMessages.ts and
/// toolGrouping.ts): subagent rows folded away, tool results joined to their calls, SendUserFile as file cards, and
/// runs of two or more calls of the same tool collapsed into one group.
enum Transcript {
    static let neverGrouped: Set<String> = ["Task", "Agent", "Workflow", "SendUserFile"]

    static func rows(_ messages: [ServerMessage]) -> [ChatRow] {
        enum Item { case row(ChatRow), call(String) }
        var items: [Item] = []
        var calls: [String: ToolCall] = [:]

        for m in messages where m.parentToolUseId == nil {
            switch m.kind {
            case "text":
                let text = m.content?.text ?? ""
                if m.role == "user" {
                    if text.hasPrefix("<task-notification>") { continue }
                    let images = (m.images ?? []).compactMap { $0["data"]?.string ?? $0["url"]?.string ?? $0.string }
                    let files = (m.files ?? []).compactMap { f -> String? in
                        f["name"]?.string ?? (f["path"]?.string).map { ($0 as NSString).lastPathComponent }
                    }
                    items.append(.row(.user(id: m.id, text: text, images: images, files: files)))
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(.row(.assistant(id: m.id, markdown: text)))
                }
            case "thinking":
                let text = m.content?.text ?? ""
                if !text.isEmpty { items.append(.row(.thinking(id: m.id, text: text))) }
            case "tool_use":
                let tid = m.toolId ?? m.id
                var call = ToolCall(id: tid, name: m.toolName ?? "", input: m.toolInput, result: nil, isError: false, toolUseResult: nil)
                if let r = m.toolResult {
                    call.result = r["content"]?.text
                    call.isError = r["isError"]?.bool ?? false
                    call.toolUseResult = r["toolUseResult"]
                }
                if calls[tid] == nil { items.append(.call(tid)) }
                calls[tid] = call
            case "tool_result":
                guard let tid = m.toolId, var call = calls[tid] else { continue }
                call.result = m.content?.text ?? ""
                call.isError = m.isError ?? false
                call.toolUseResult = m.toolUseResult
                calls[tid] = call
            case "error":
                let text = m.content?.text ?? m.error ?? ""
                if !text.isEmpty { items.append(.row(.error(id: m.id, text: text))) }
            default:
                continue
            }
        }

        var out: [ChatRow] = []
        var run: [ToolCall] = []
        func flush() {
            if run.count >= 2 { out.append(.toolGroup(id: "group-" + run[0].id, name: run[0].name, calls: run)) }
            else if let c = run.first { out.append(.tool(id: c.id, c)) }
            run = []
        }
        for item in items {
            switch item {
            case .row(let r):
                flush(); out.append(r)
            case .call(let tid):
                guard let c = calls[tid] else { continue }
                if c.name == "SendUserFile" && !c.isError {
                    flush()
                    let input = c.input?.parsedObject
                    var paths: [String] = input?["files"]?.array?.compactMap { $0.string } ?? []
                    if paths.isEmpty, let one = input?["files"]?.string { paths = [one] }
                    var sizes: [String: Int] = [:]
                    for a in c.toolUseResult?["attachments"]?.array ?? [] {
                        if let p = a["path"]?.string?.workspaceRelative, let s = a["size"]?.number { sizes[p] = Int(s) }
                    }
                    var seen = Set<String>()
                    let files = paths.compactMap { $0.workspaceRelative }.filter { seen.insert($0).inserted }
                        .map { SentFile(path: $0, size: sizes[$0]) }
                    let caption = input?["caption"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(.sentFiles(id: c.id, caption: caption?.isEmpty == false ? caption : nil, files: files, sending: c.result == nil))
                    continue
                }
                if neverGrouped.contains(c.name) { flush(); out.append(.tool(id: c.id, c)); continue }
                if let last = run.last, last.name != c.name { flush() }
                run.append(c)
            }
        }
        flush()
        return out
    }
}

/// The empty chat's greeting: DE0CH/claudecodeui src/modules/chat/utils/jarvisGreeting.ts (same phrases and rules).
enum Greeting {
    enum Slot { case morning, afternoon, evening, night }

    struct Phrases { var slots: [Slot: [String]]; var anytime: [String]; var daytime: [String]; var returning: [String] }

    static let zh = Phrases(
        slots: [.morning: ["早晨", "早呀", "早晨！今日精神嗎？"], .afternoon: ["下晝好", "食咗飯未呀？"],
                .evening: ["夜晚好", "食咗飯未呀？"], .night: ["夜喇，仲未瞓？", "早唞"]],
        anytime: ["你好呀", "你好", "哈囉", "嗨", "喂，你好", "哈囉哈囉", "嘿", "你好嗎？", "點呀？", "近排點呀？", "一切順利嗎？",
                  "最近過成點？", "有咩新嘢？", "而家發生緊咩事？"],
        daytime: ["今日打得掂嗎？"], returning: ["又見面喇", "歡迎返嚟"])

    static let en = Phrases(
        slots: [.morning: ["Good morning", "Morning", "Top of the morning"], .afternoon: ["Good afternoon", "How's it going?"],
                .evening: ["Good evening", "How's everything?"], .night: ["Hello again", "Hi there"]],
        anytime: ["Good day", "Hello", "Hi", "Hey", "Hello there", "Hiya", "Hey there", "How are you?", "How are you doing?",
                  "How's it going?", "How's everything?", "How's life?", "What's new?", "What's going on?"],
        daytime: ["How goes the battle?"], returning: ["Hello again", "Welcome"])

    /// 05:00–11:59 morning, 12:00–17:59 afternoon, 18:00–22:59 evening, 23:00–04:59 night, Hong Kong time.
    static func slot(at d: Date) -> Slot {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        let h = cal.component(.hour, from: d)
        if h >= 5 && h < 12 { return .morning }
        if h >= 12 && h < 18 { return .afternoon }
        if h >= 18 && h < 23 { return .evening }
        return .night
    }

    static func pool(chinese: Bool, slot: Slot, returning: Bool) -> [String] {
        let p = chinese ? zh : en
        return (p.slots[slot] ?? []) + p.anytime + (slot == .morning || slot == .afternoon ? p.daytime : []) + (returning ? p.returning : [])
    }

    static func text(chinese: Bool, date: Date, draw: Double, name: String?, returning: Bool) -> String {
        let list = pool(chinese: chinese, slot: slot(at: date), returning: returning)
        var g = list[min(list.count - 1, Int(draw * Double(list.count)))]
        guard let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return g }
        var end = ""
        if let last = g.last, last == "？" || last == "?" { end = String(last); g.removeLast() }
        return chinese ? "\(g)，\(n)\(end)" : "\(g), \(n)\(end)"
    }

    /// One draw per app launch, like one per page load.
    static let draw = Double.random(in: 0..<1)
}
