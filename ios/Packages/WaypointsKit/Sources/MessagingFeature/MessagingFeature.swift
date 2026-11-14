import Core
import DesignSystem
import PhotosUI
import SwiftUI

/// Channel and thread chat (plan 10.7 T2, T7). Routes `channel` and `thread`.
public enum MessagingFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.channel, presentation: .push(tab: .teams)) { route in
            guard case let .channel(id) = route else { return nil }
            return AnyView(ChatView(env: env, target: .channel(id)))
        }
        registry.registerRoute(.thread, presentation: .push(tab: .teams)) { route in
            guard case let .thread(id) = route else { return nil }
            return AnyView(ChatView(env: env, target: .thread(id)))
        }
    }
}

/// A message on screen: confirmed, sending, or failed.
struct ChatItem: Identifiable, Hashable {
    enum State: Hashable { case sent, sending, failed }
    var id: String
    var message: Message
    var state: State
}

@MainActor
@Observable
final class ChatModel {
    let env: AppEnvironment
    let target: MessageTarget
    var items: [ChatItem] = []
    var profiles: [UserID: Profile] = [:]
    var roles: [UserID: TeamRole] = [:]
    var title = ""
    var me: UserID?
    var loadingOlder = false
    var reachedStart = false
    var canDelete = false
    var listing: Listing?
    var members: [Profile] = []
    var teamID: TeamID?
    var offline = false
    var error: String?

    init(env: AppEnvironment, target: MessageTarget) { self.env = env; self.target = target }

    func load() async {
        me = await env.auth.currentSession()?.userID
        switch target {
        case let .channel(id):
            if let c = try? await env.teams.channel(id) {
                title = "#\(c.name)"
                teamID = c.teamID
                canDelete = (try? await env.teams.myPermissions(in: c.teamID).contains(.deleteMessages)) ?? false
                let teamRoles = (try? await env.teams.roles(of: c.teamID)) ?? []
                let ms = (try? await env.teams.members(of: c.teamID)) ?? []
                for m in ms { if let r = teamRoles.first(where: { $0.id == m.roleID }) { roles[m.userID] = r } }
                members = (try? await env.profiles.profiles(ms.map(\.userID))) ?? []
                for p in members { profiles[p.userID] = p }
            }
        case let .thread(id):
            if let t = try? await env.messages.threads().first(where: { $0.id == id }), let me {
                let other = t.other(than: me)
                if let p = try? await env.profiles.profile(other) { profiles[other] = p; title = p.displayName }
                if let l = t.listingID { listing = try? await env.market.listing(l) }
            }
        }
        let page = (try? await env.messages.messages(in: target, before: nil, limit: 50)) ?? []
        reachedStart = page.count < 50
        items = page.reversed().map { ChatItem(id: "m\($0.id.raw)", message: $0, state: .sent) }
        await resolveAuthors()
        markRead()
    }

    func listen() async {
        for await m in await env.messages.live(target) {
            if let i = items.firstIndex(where: { $0.message.id == m.id }) {
                items[i].message = m
            } else if let i = items.firstIndex(where: { $0.state == .sending && $0.message.body == m.body && $0.message.authorID == m.authorID }) {
                items[i] = ChatItem(id: "m\(m.id.raw)", message: m, state: .sent)
            } else {
                items.append(ChatItem(id: "m\(m.id.raw)", message: m, state: .sent))
            }
            await resolveAuthors()
            markRead()
        }
    }

    /// MSG-10: offline disables the composer; loaded messages stay on screen.
    func watchConnection() async {
        for await state in await env.realtime.connectionState() {
            switch state {
            case .offline: offline = true
            case .live: offline = false
            case .connecting, .reconnecting: break
            }
        }
    }

    func loadOlder() async {
        guard !loadingOlder, !reachedStart, let first = items.first(where: { $0.state == .sent })?.message.id else { return }
        loadingOlder = true
        let page = (try? await env.messages.messages(in: target, before: first, limit: 50)) ?? []
        reachedStart = page.count < 50
        items.insert(contentsOf: page.reversed().map { ChatItem(id: "m\($0.id.raw)", message: $0, state: .sent) }, at: 0)
        loadingOlder = false
        await resolveAuthors()
    }

    private func resolveAuthors() async {
        let missing = Set(items.map(\.message.authorID)).filter { profiles[$0] == nil }
        guard !missing.isEmpty else { return }
        for p in (try? await env.profiles.profiles(Array(missing))) ?? [] { profiles[p.userID] = p }
    }

    private func markRead() {
        guard let last = items.last(where: { $0.state == .sent })?.message.id else { return }
        let t = target
        Task { try? await env.messages.markRead(t, upTo: last) }
    }

    func send(_ text: String, attachment: String? = nil) async -> Bool {
        guard let me else { return false }
        if case .blocked = await env.safety.check(text) {
            error = "That message can't be sent."
            return false
        }
        error = nil
        let local = ChatItem(id: UUID().uuidString, message: Message(id: MessageID(raw: -Int64(items.count) - 1), target: target,
                                                                     authorID: me, body: text, attachmentPath: attachment),
                             state: .sending)
        items.append(local)
        do {
            let m = try await env.messages.send(text, attachmentPath: attachment, to: target)
            if let i = items.firstIndex(where: { $0.id == local.id }) {
                if items.contains(where: { $0.message.id == m.id }) { items.remove(at: i) } else {
                    items[i] = ChatItem(id: "m\(m.id.raw)", message: m, state: .sent)
                }
            }
        } catch {
            if case WaypointsError.rateLimited = error { self.error = "You're doing that a lot. Try again in a few minutes." }
            if let i = items.firstIndex(where: { $0.id == local.id }) { items[i].state = .failed }
        }
        return true
    }

    func retry(_ item: ChatItem) async {
        items.removeAll { $0.id == item.id }
        _ = await send(item.message.body, attachment: item.message.attachmentPath)
    }

    func delete(_ item: ChatItem) {
        Task {
            try? await env.messages.delete(item.message.id)
            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].message.deletedAt = .now }
        }
    }
}

struct ChatView: View {
    @State private var model: ChatModel
    @State private var draft = ""
    @State private var sendTick = 0
    @State private var photo: PhotosPickerItem?
    @State private var pickPhoto = false
    @State private var zoom: URL?

    init(env: AppEnvironment, target: MessageTarget) { _model = State(initialValue: ChatModel(env: env, target: target)) }

    private var placeholder: LocalizedStringKey {
        if model.offline { return "Offline" }
        if case .channel = model.target { return "Message \(model.title)" }
        return "Message"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let l = model.listing { listingRow(l) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.loadingOlder { SkeletonRow(); SkeletonRow(); SkeletonRow() }
                        if model.reachedStart {
                            Text(model.title.hasPrefix("#") ? "This is the start of \(model.title)." : "This is the start of your conversation.")
                                .typeStyle(.sub).foregroundStyle(Color.dust).padding(Space.margin)
                        } else {
                            Color.clear.frame(height: 1).onAppear { Task { await model.loadOlder() } }
                        }
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || !Calendar.current.isDate(model.items[i - 1].message.createdAt, inSameDayAs: item.message.createdAt) {
                                Text(verbatim: item.message.createdAt.formatted(date: .abbreviated, time: .omitted).uppercased())
                                    .typeStyle(.label).foregroundStyle(Color.dust).frame(maxWidth: .infinity).padding(.vertical, Space.s12)
                            }
                            bubble(item, grouped: i > 0 && grouped(model.items[i - 1], item)).id(item.id)
                        }
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.items.count) { if let last = model.items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            composer
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .haptic(.tap, trigger: sendTick)
        .photosPicker(isPresented: $pickPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) {
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self),
                   let media = try? await model.env.media.upload(data, contentType: "image/jpeg", to: .messages, progress: { _ in }) {
                    _ = await model.send(draft, attachment: media.path)
                    draft = ""
                }
                self.photo = nil
            }
        }
        .sheet(item: Binding(get: { zoom.map(ZoomURL.init) }, set: { zoom = $0?.url })) { z in
            MediaView(url: z.url, label: Text("Photo", bundle: .module)).background(Color.asphalt)
        }
        .task { await model.load() }
        .task { await model.listen() }
        .task { await model.watchConnection() }
        .toolbar {
            if let team = model.teamID {
                ToolbarItem(placement: .topBarTrailing) {
                    IconButton("person.2", label: "Members") { model.env.router.open(.team(team)) }
                }
            }
        }
    }

    private func grouped(_ a: ChatItem, _ b: ChatItem) -> Bool {
        a.message.authorID == b.message.authorID && b.message.createdAt.timeIntervalSince(a.message.createdAt) < 300
    }

    private func bubble(_ item: ChatItem, grouped: Bool) -> some View {
        let author = model.profiles[item.message.authorID]
        let role = model.roles[item.message.authorID]
        return HStack(alignment: .top, spacing: Space.s12) {
            if grouped {
                Color.clear.frame(width: Avatar.Diameter.s40.rawValue)
            } else {
                Avatar(name: author?.displayName ?? "", url: author?.avatarPath.map { model.env.media.publicURL(bucket: .avatars, path: $0) }, size: .s40)
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                if !grouped {
                    HStack(spacing: Space.s8) {
                        Text(verbatim: author?.displayName ?? "").typeStyle(.bodyStrong)
                            .foregroundStyle(role?.colorHex.flatMap { Color(paintHex: $0) } ?? Color.chalk)
                        Text(verbatim: item.message.createdAt.formatted(date: .omitted, time: .shortened)).typeStyle(.foot).foregroundStyle(Color.gravel)
                    }
                }
                if item.message.deletedAt != nil {
                    Text("Message deleted", bundle: .module).typeStyle(.sub).italic().foregroundStyle(Color.gravel)
                } else {
                    if !item.message.body.isEmpty { Text(verbatim: item.message.body).typeStyle(.body).foregroundStyle(Color.chalk) }
                    if let path = item.message.attachmentPath {
                        let url = model.env.media.publicURL(bucket: .messages, path: path)
                        Button { zoom = url } label: {
                            MediaView(url: url, aspectRatio: 4.0 / 3.0, cornerRadius: Radius.r12, label: Text("Photo", bundle: .module))
                                .frame(maxWidth: Size.row * 4)
                        }
                    }
                }
                if item.state == .failed {
                    Button { Task { await model.retry(item) } } label: {
                        Text("Not sent. Tap to retry.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.brake)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(item.state == .sending ? 0.6 : 1)
        .padding(.horizontal, Space.margin)
        .padding(.top, grouped ? Space.s2 : Space.s12)
        .contextMenu {
            Button("Copy") { UIPasteboard.general.string = item.message.body }
            Button("Reply") { draft = "> \(item.message.body.split(separator: "\n").first ?? "")\n" }
            if item.message.authorID == model.me || model.canDelete {
                Button("Delete", role: .destructive) { model.delete(item) }
            }
            if item.message.authorID != model.me {
                Button("Report") {
                    model.env.router.open(.reportContent(ContentRef(kind: .message, id: String(item.message.id.raw))))
                }
            }
        }
    }

    private var mentionMatches: [Profile] {
        guard case .channel = model.target, let at = draft.split(separator: " ", omittingEmptySubsequences: false).last,
              at.hasPrefix("@") else { return [] }
        let q = at.dropFirst().lowercased()
        return model.members.filter { q.isEmpty || $0.handle.hasPrefix(q) }.prefix(5).map { $0 }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            ForEach(mentionMatches) { p in
                Button {
                    var parts = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                    parts[parts.count - 1] = "@\(p.handle) "
                    draft = parts.joined(separator: " ")
                } label: { Row(Text(verbatim: p.displayName), subtitle: Text(verbatim: "@\(p.handle)")) }
                    .buttonStyle(RowButtonStyle())
            }
            if let e = model.error { Text(verbatim: e).typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin) }
            HStack(spacing: Space.s8) {
                IconButton(Symbol.photo, label: "Photo") { pickPhoto = true }
                    .disabled(model.offline)
                Field("Message", text: $draft, prompt: placeholder, limit: 2000, axis: .vertical)
                    .disabled(model.offline)
                IconButton(Symbol.send, label: "Send") {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    sendTick += 1
                    Task { if !(await model.send(text)) { draft = text } }
                }
                .disabled(model.offline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, Space.s12)
            .padding(.vertical, Space.s8)
        }
        .background(Color.tarmac)
        .overlay(alignment: .top) { Hairline() }
    }

    private func listingRow(_ l: Listing) -> some View {
        Button { model.env.router.open(.listing(l.id)) } label: {
            Row(Text(verbatim: l.title), subtitle: Text(verbatim: (Double(l.priceCents) / 100).formatted(.currency(code: "USD").precision(.fractionLength(0)))),
                leading: {
                    MediaView(url: l.photos.first.map { model.env.media.publicURL(bucket: .listings, path: $0.path) }, aspectRatio: 1,
                              cornerRadius: Radius.r6, label: Text(verbatim: l.title))
                        .frame(width: Size.hitTarget, height: Size.hitTarget)
                }, trailing: { Text(verbatim: l.status.rawValue.capitalized).typeStyle(.foot) })
        }
        .buttonStyle(RowButtonStyle())
        .background(Color.tarmac)
    }
}

struct ZoomURL: Identifiable { let url: URL; var id: URL { url } }
