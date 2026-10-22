import MarkdownUI
import QuickLook
import SwiftUI

struct ChatScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showFiles = false
    @State private var showShare = false
    @State private var preview: URL?

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if !model.connected {
                Text(L("status.reconnecting")).font(.footnote).frame(maxWidth: .infinity).padding(6)
                    .background(.yellow.opacity(0.25))
            }
            if let b = model.banner {
                HStack {
                    Text(b).font(.footnote)
                    Spacer()
                    Button { model.banner = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(L("button.close"))
                }
                .padding(8).background(.red.opacity(0.15))
            }
            if model.rows.isEmpty && !model.loadingHistory {
                EmptyChat()
            } else {
                transcript
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if model.isBusy { ActivityIndicator() }
                Composer()
            }
            .padding(.horizontal, 12).padding(.bottom, 6).padding(.top, 4)
            .background(.bar)
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.selected != nil {
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(L("share.button")).accessibilityIdentifier("share-button")
                    Button { showFiles = true } label: { Image(systemName: "folder") }
                        .accessibilityLabel(L("files.title")).accessibilityIdentifier("files-button")
                }
                Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(L("chat.new")).accessibilityIdentifier("new-chat-button")
            }
        }
        .sheet(isPresented: $showFiles) { FilesPanel() }
        .sheet(isPresented: $showShare) { ShareSheet() }
        .quickLookPreview($preview)
        .environment(\.openSentFile, OpenSentFile { path, name in
            Task { preview = await model.previewFile(path: path, name: name) }
        })
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.olderAvailable {
                        Button(L("chat.loadOlder")) { model.loadOlder() }.frame(maxWidth: .infinity)
                    }
                    ForEach(model.rows) { row in
                        RowView(row: row).id(row.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.rows.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .accessibilityIdentifier("transcript")
        }
    }
}

struct OpenSentFile { var open: (String, String) -> Void; init(_ f: @escaping (String, String) -> Void) { open = f } }
private struct OpenSentFileKey: EnvironmentKey { static let defaultValue = OpenSentFile { _, _ in } }
extension EnvironmentValues {
    var openSentFile: OpenSentFile { get { self[OpenSentFileKey.self] } set { self[OpenSentFileKey.self] = newValue } }
}

struct EmptyChat: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            LogoImage(size: 56)
            Text(model.nameLoaded ? Greeting.text(chinese: uiIsChinese, date: Date(), draw: Greeting.draw, name: model.firstName,
                                                  returning: model.returning) : " ")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("empty-greeting")
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RowView: View {
    var row: ChatRow

    var body: some View {
        switch row {
        case .user(_, let text, let images, let files):
            UserBubble(text: text, images: images, files: files)
        case .assistant(_, let md):
            Markdown(md)
                .markdownTheme(.gitHub.text { BackgroundColor(nil) })
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking(_, let text):
            DisclosureGroup {
                Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            } label: {
                Label(L("chat.thinking"), systemImage: "brain").font(.callout).foregroundStyle(.secondary)
            }
        case .tool(_, let call):
            ToolView(call: call)
        case .toolGroup(_, let name, let calls):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) { ForEach(calls) { ToolView(call: $0) } }
            } label: {
                let names = calls.prefix(2).map(\.summary).filter { !$0.isEmpty }.joined(separator: ", ")
                Label("\(name) · \(names)\(calls.count > 2 ? " " + L("tool.more", calls.count - 2) : "")", systemImage: "wrench.and.screwdriver")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        case .sentFiles(_, let caption, let files, let sending):
            SentFilesView(caption: caption, files: files, sending: sending)
        case .error(_, let text):
            Label {
                Text(text).textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .accessibilityLabel(L("chat.error") + ": " + text)
        }
    }
}

struct UserBubble: View {
    var text: String
    var images: [String]
    var files: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !images.isEmpty {
                HStack { ForEach(Array(images.enumerated()), id: \.offset) { _, s in DataURLImage(s: s) } }
            }
            ForEach(files, id: \.self) { f in
                Label(f, systemImage: "doc").font(.footnote).padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            if !text.isEmpty {
                Text(text).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 40)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("user-message")
    }
}

struct DataURLImage: View {
    var s: String
    var body: some View {
        if let comma = s.firstIndex(of: ","), let d = Data(base64Encoded: String(s[s.index(after: comma)...])), let ui = UIImage(data: d) {
            Image(uiImage: ui).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(L("chat.image"))
        }
    }
}

struct ToolView: View {
    var call: ToolCall
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if let i = call.input { Text(String(i.parsedObject.text.prefix(4000))).font(.caption.monospaced()).textSelection(.enabled) }
                if let r = call.result {
                    Text(String(r.prefix(4000))).font(.caption.monospaced()).foregroundStyle(call.isError ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                if call.result == nil { ProgressView().controlSize(.mini) } else if call.isError {
                    Image(systemName: "xmark.circle").foregroundStyle(.red)
                } else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                Text(call.summary.isEmpty ? call.name : "\(call.name) · \(call.summary)").lineLimit(1)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct SentFilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSentFile) private var openFile
    var caption: String?
    var files: [SentFile]
    var sending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let caption { Text(caption) }
            ForEach(files) { f in
                Button { openFile.open(f.path, f.name) } label: {
                    HStack(spacing: 12) {
                        if isImage(f.name), let id = model.selected, let api = model.api {
                            AuthImage(path: api.rawPath(id, f.path, inline: true)).frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            Image(systemName: icon(f.name)).font(.title2).frame(width: 56, height: 56)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Text(sending ? L("sent.sending") : Format.size(f.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .accessibilityLabel(L("sent.open", f.name))
                .accessibilityIdentifier("file-card")
            }
        }
    }

    private func isImage(_ n: String) -> Bool { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((n as NSString).pathExtension.lowercased()) }
    private func icon(_ n: String) -> String {
        switch (n as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "xlsx", "xls", "csv": return "tablecells"
        case "docx", "doc", "md", "txt": return "doc.text"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }
}

/// An image the server serves behind the Access token.
struct AuthImage: View {
    @Environment(AppModel.self) private var model
    var path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
        }
        .task(id: path) {
            if let d = try? await model.api?.data(path) { image = UIImage(data: d) }
        }
    }
}

struct ActivityIndicator: View {
    @Environment(AppModel.self) private var model
    static let actions = ["thinking", "processing", "analyzing", "working", "computing", "reasoning"]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 10) {
                switch model.phase {
                case .preparing(let since):
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("status.preparing")).font(.callout)
                        if ctx.date.timeIntervalSince(since) >= 20 { Text(L("status.preparingSlow")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .accessibilityIdentifier("preparing-indicator")
                    Spacer()
                case .working(let since):
                    let secs = Int(ctx.date.timeIntervalSince(since))
                    ProgressView().controlSize(.small)
                    Text(L("status.action." + Self.actions[(secs / 4) % Self.actions.count])).font(.callout)
                    Text(secs < 60 ? L("status.seconds", secs) : L("status.minutesSeconds", secs / 60, secs % 60))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("button.stop")) { model.stop() }.buttonStyle(.bordered).controlSize(.small)
                        .accessibilityIdentifier("stop-button")
                case .idle:
                    EmptyView()
                }
            }
        }
    }
}
