import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var compact: NavigationSplitViewColumn = .detail
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compact) {
            sidebar
        } detail: {
            NavigationStack { ChatScreen() }
        }
        .alert(L("menu.rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("menu.rename"), text: $renameText)
            Button(L("button.cancel"), role: .cancel) { renaming = nil }
            Button(L("button.save")) {
                if let c = renaming { model.rename(c.id, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(L("delete.title"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button(L("button.delete"), role: .destructive) {
                if let c = deleting { model.delete(c.id) }
                deleting = nil
            }
            .accessibilityIdentifier("confirm-delete")
        } message: {
            Text(L("delete.confirm", deleting?.title ?? "") + "\n" + L("delete.notice"))
        }
    }

    private var sidebar: some View {
        List {
            Button {
                model.newChat()
                compact = .detail
            } label: {
                Label(L("chat.new"), systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("sidebar-new-chat")
            Section(L("list.title")) {
                if model.conversations.isEmpty {
                    Text(L("list.empty")).foregroundStyle(.secondary)
                }
                ForEach(model.conversations) { c in
                    Button {
                        model.open(c.id)
                        compact = .detail
                    } label: {
                        ConversationRow(c: c, running: model.running.contains(c.id), selected: model.selected == c.id)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleting = c } label: { Label(L("button.delete"), systemImage: "trash") }
                        Button { renameText = c.title; renaming = c } label: { Label(L("menu.rename"), systemImage: "pencil") }
                    }
                    .contextMenu {
                        Button { renameText = c.title; renaming = c } label: { Label(L("menu.rename"), systemImage: "pencil") }
                        Button(role: .destructive) { deleting = c } label: { Label(L("button.delete"), systemImage: "trash") }
                    }
                }
                if model.hasMore {
                    Button(L("list.loadMore")) { model.loadMore() }
                }
            }
            Section {
                NavigationLink {
                    DeletedList()
                } label: {
                    Label(L("deleted.title"), systemImage: "trash")
                }
            }
        }
        .accessibilityIdentifier("conversation-list")
        .navigationTitle(Config.appName)
        .refreshable { await model.loadList() }
    }
}

struct ConversationRow: View {
    var c: Conversation
    var running: Bool
    var selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left").foregroundStyle(.secondary)
            Text(c.title.isEmpty ? L("list.unnamed") : c.title).lineLimit(1)
                .fontWeight(selected ? .semibold : .regular)
            Spacer(minLength: 4)
            if running { ProgressView().controlSize(.small) } else if let d = c.lastActivity {
                Text(Format.age(d)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DeletedList: View {
    @Environment(AppModel.self) private var model
    @State private var purging: Conversation?

    var body: some View {
        List {
            Text(L("deleted.hint")).font(.footnote).foregroundStyle(.secondary)
            if model.deletedConversations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("deleted.empty"))
                    Text(L("deleted.emptyHint")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(model.deletedConversations) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title.isEmpty ? L("list.unnamed") : c.title).lineLimit(1)
                    if let p = c.purgeAt {
                        let days = Int(ceil(p.timeIntervalSinceNow / 86400))
                        Text(days <= 0 ? L("deleted.dueNow") : L("deleted.daysLeft", days)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("deleted-row")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { purging = c } label: { Label(L("deleted.purge"), systemImage: "trash") }
                    Button { model.restore(c.id) } label: { Label(L("deleted.restore"), systemImage: "arrow.uturn.backward") }.tint(.blue)
                }
                .contextMenu {
                    Button { model.restore(c.id) } label: { Label(L("deleted.restore"), systemImage: "arrow.uturn.backward") }
                    Button(role: .destructive) { purging = c } label: { Label(L("deleted.purge"), systemImage: "trash") }
                }
            }
        }
        .navigationTitle(L("deleted.title"))
        .onAppear { model.loadDeleted() }
        .refreshable { model.loadDeleted() }
        .confirmationDialog(L("deleted.purgeTitle"), isPresented: Binding(get: { purging != nil }, set: { if !$0 { purging = nil } }),
                            titleVisibility: .visible) {
            Button(L("deleted.purge"), role: .destructive) {
                if let c = purging { model.deletePermanently(c.id) }
                purging = nil
            }
        } message: {
            Text(L("deleted.purgeConfirm", purging?.title ?? "") + "\n" + L("deleted.purgeNotice"))
        }
    }
}

enum Format {
    static func age(_ d: Date) -> String {
        let s = max(0, Date().timeIntervalSince(d))
        if s < 60 { return L("age.now") }
        if s < 3600 { return L("age.minutes", Int(s / 60)) }
        if s < 86400 { return L("age.hours", Int(s / 3600)) }
        return L("age.days", Int(s / 86400))
    }

    /// 1 KB = 1024 bytes, one decimal place, like the web UI.
    static func size(_ n: Int?) -> String {
        guard let n else { return "" }
        if n < 1024 { return "\(n) B" }
        let units = ["KB", "MB", "GB"]
        var v = Double(n) / 1024
        var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: "%.1f %@", v, units[i])
    }
}
