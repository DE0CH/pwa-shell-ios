import QuickLook
import SwiftUI

/// 檔案: the files Claude sent in this conversation (GET /api/jarvis/sessions/:id/files).
struct FilesPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var files: [API.WorkspaceFile] = []
    @State private var state = "loading"
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case "loading": ProgressView(L("files.loading"))
                case "error":
                    VStack(spacing: 12) {
                        Text(L("files.loadError"))
                        Button(L("files.retry")) { Task { await load() } }
                    }
                default:
                    if files.isEmpty {
                        Text(model.selected == nil ? L("files.notStarted") : L("files.empty", Config.appName))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(32)
                    } else {
                        List(files) { f in
                            Button {
                                Task { preview = await model.previewFile(path: f.path, name: f.name) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(f.name).font(.body.weight(.medium))
                                    if let c = f.caption { Text(c).font(.callout).foregroundStyle(.secondary) }
                                    Text(meta(f)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .refreshable { await load() }
                    }
                }
            }
            .navigationTitle(L("files.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("button.close")) { dismiss() } } }
            .quickLookPreview($preview)
        }
        .task { await load() }
    }

    private func meta(_ f: API.WorkspaceFile) -> String {
        var parts: [String] = []
        let dir = (f.path as NSString).deletingLastPathComponent
        if !dir.isEmpty { parts.append(dir) }
        if f.size != nil { parts.append(Format.size(f.size)) }
        if let d = f.sentAt { parts.append(d.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let api = model.api, let id = model.selected else { files = []; state = "done"; return }
        do { files = try await api.files(id); state = "done" } catch API.Failure.signedOut { model.signedOut() } catch { state = "error" }
    }
}

/// 分享: read-only snapshot links for colleagues (POST/GET /api/jarvis/sessions/:id/shares, DELETE /api/jarvis/shares/:id).
struct ShareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shares: [API.Share] = []
    @State private var creating = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L("share.lead", Config.appName)).font(.callout).foregroundStyle(.secondary)
                    Button {
                        Task { await create() }
                    } label: {
                        if creating { Label(L("share.creating"), systemImage: "hourglass") } else { Label(L("share.create"), systemImage: "link") }
                    }
                    .disabled(creating)
                    if let message { Text(message).font(.callout).foregroundStyle(.red) }
                }
                if !shares.isEmpty {
                    Section(L("share.links")) {
                        ForEach(shares) { s in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(s.url.absoluteString).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                HStack {
                                    ShareLink(item: s.url) { Label(L("share.shareLink"), systemImage: "square.and.arrow.up") }
                                    Spacer()
                                    Button(L("share.copy")) { UIPasteboard.general.url = s.url; message = nil }
                                    Spacer()
                                    Button(L("share.stop"), role: .destructive) { Task { await stop(s) } }
                                }
                                .buttonStyle(.borderless).font(.callout)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("share.button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("button.close")) { dismiss() } } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = model.api, let id = model.selected else { return }
        shares = (try? await api.shares(id)) ?? []
    }

    private func create() async {
        guard let api = model.api, let id = model.selected else { return }
        creating = true
        defer { creating = false }
        do {
            let s = try await api.createShare(id)
            shares.insert(s, at: 0)
            message = nil
        } catch API.Failure.http(400, _) {
            message = L("share.nothing")
        } catch {
            message = L("share.failed")
        }
    }

    private func stop(_ s: API.Share) async {
        guard let api = model.api else { return }
        if (try? await api.stopShare(s.id)) != nil { shares.removeAll { $0.id == s.id } }
    }
}
