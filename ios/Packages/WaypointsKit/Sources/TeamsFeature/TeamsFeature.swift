import Core
import DesignSystem
import PhotosUI
import SwiftUI

/// The Teams tab (plan 10.7 T1, T4, T5, T6) and routes `team`, `joinTeam`.
public enum TeamsFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let model = TeamsModel(env: env, registry: registry)
        registry.registerTab(.teams, badge: { model.unread }) { AnyView(TeamsHome(model: model)) }
        registry.registerRoute(.team, presentation: .push(tab: .teams)) { route in
            guard case let .team(id) = route else { return nil }
            return AnyView(TeamDetail(model: model, teamID: id))
        }
        registry.registerRoute(.joinTeam, presentation: .sheet) { route in
            guard case let .joinTeam(code) = route else { return nil }
            return AnyView(FindOrStart(model: model, code: code))
        }
        model.start()
    }
}

@MainActor
@Observable
final class TeamsModel {
    let env: AppEnvironment
    let registry: FeatureRegistry
    var teams: [Team] = []
    var selected: TeamID?
    var channels: [Channel] = []
    var threads: [MessageThread] = []
    var people: [UserID: Profile] = [:]
    var friends: Set<UserID> = []
    var upcoming: Meet?
    var unread = 0
    var me: UserID?
    var loaded = false

    init(env: AppEnvironment, registry: FeatureRegistry) { self.env = env; self.registry = registry }

    func start() {
        let env = self.env
        Task { [weak self] in
            for await n in await env.messages.unreadCount() { self?.unread = n }
        }
    }

    func load() async {
        me = await env.auth.currentSession()?.userID
        teams = (try? await env.teams.myTeams()) ?? []
        threads = (try? await env.messages.threads()) ?? []
        friends = Set(((try? await env.friends.friends()) ?? []).map(\.id))
        if let me {
            for p in (try? await env.profiles.profiles(threads.map { $0.other(than: me) })) ?? [] { people[p.userID] = p }
        }
        if selected == nil { selected = teams.first?.id }
        await loadTeam()
        loaded = true
    }

    func loadTeam() async {
        guard let id = selected else { channels = []; return }
        channels = (try? await env.teams.channels(of: id)) ?? []
        if let me {
            upcoming = (try? await env.meets.upcomingMeets(for: me))?.first { $0.teamID == id }
        }
    }
}

// MARK: T1

struct TeamsHome: View {
    @Bindable var model: TeamsModel
    @State private var dms = false
    @State private var showFind = false

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Color.seam).frame(width: 1)
            ScrollView {
                if !model.loaded {
                    SkeletonRow(); SkeletonRow(); SkeletonRow()
                } else if dms || model.teams.isEmpty && !model.threads.isEmpty {
                    directMessages
                } else if let team = model.teams.first(where: { $0.id == model.selected }) {
                    teamPane(team)
                } else {
                    VStack(alignment: .leading, spacing: Space.s16) {
                        Text("Teams are where your people talk. Join one or start your own.").typeStyle(.body).foregroundStyle(Color.chalk)
                        PrimaryButton("Find a team") { showFind = true }
                        SecondaryButton("Start a team") { showFind = true }
                    }
                    .padding(Space.margin)
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Teams")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFind, onDismiss: { Task { await model.load() } }) { FindOrStart(model: model, code: "") }
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: Space.s12) {
                Button { dms = true } label: {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title3)
                        .foregroundStyle(dms ? Color.sodium : Color.chalk)
                        .frame(width: Size.hitTarget, height: Size.hitTarget)
                        .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12))
                        .overlay(alignment: .topTrailing) {
                            if model.unread > 0 {
                                Text(verbatim: "\(model.unread)").typeStyle(.readoutS).foregroundStyle(Color.chalk)
                                    .padding(.horizontal, Space.s4).background(Color.brake, in: Capsule())
                            }
                        }
                }
                .accessibilityLabel(Text("Direct messages"))
                Hairline().frame(width: Size.hitTarget)
                ForEach(model.teams) { t in
                    Button {
                        dms = false
                        model.selected = t.id
                        Task { await model.loadTeam() }
                    } label: { TeamIcon(team: t, env: model.env, size: Size.hitTarget, selected: !dms && model.selected == t.id) }
                }
                IconButton(Symbol.add, label: "Find or start a team") { showFind = true }
            }
            .padding(.vertical, Space.s12)
        }
        .frame(width: 64)
        .background(Color.tarmac)
    }

    private func teamPane(_ team: Team) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.env.router.open(.team(team.id)) } label: {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(verbatim: team.name).typeStyle(.title).foregroundStyle(Color.chalk)
                    HStack {
                        Text(verbatim: team.tag).typeStyle(.readoutS).foregroundStyle(Color.sodium)
                        Text("\(team.memberCount) members").typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.margin)
            }
            SectionLabel("TEXT")
            ForEach(model.channels.filter { $0.kind == .text }) { c in
                Button { model.env.router.open(.channel(c.id)) } label: { Row(Text(verbatim: "# \(c.name)")) }
                    .buttonStyle(RowButtonStyle())
            }
            let voice = model.channels.filter { $0.kind == .voice }
            if !voice.isEmpty && model.registry.canOpen(.voice(voice[0].id)) {
                SectionLabel("VOICE")
                ForEach(voice) { c in
                    Button { model.env.router.open(.voice(c.id)) } label: {
                        Row(Text(verbatim: c.name), leading: { Image.symbol(Symbol.speaker).foregroundStyle(Color.dust) })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            if let m = model.upcoming {
                SectionLabel("UPCOMING")
                Button { model.env.router.open(.meet(m.id)) } label: {
                    Row(Text(verbatim: m.title), trailing: {
                        Text(verbatim: m.startsAt.formatted(date: .abbreviated, time: .shortened)).typeStyle(.readoutS)
                    })
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    private var directMessages: some View {
        let requests = model.threads.filter { t in model.me.map { !model.friends.contains(t.other(than: $0)) && t.kind == .dm && t.lastMessage?.authorID != $0 } ?? false }
        let rest = model.threads.filter { t in !requests.contains(t) }
        return VStack(alignment: .leading, spacing: 0) {
            if model.threads.isEmpty {
                Text("No messages yet.").typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
            }
            if !requests.isEmpty {
                SectionLabel("REQUESTS")
                ForEach(requests) { threadRow($0, request: true) }
                SectionLabel("MESSAGES")
            }
            ForEach(rest) { threadRow($0, request: false) }
        }
    }

    private func threadRow(_ t: MessageThread, request: Bool) -> some View {
        let other = model.me.map { t.other(than: $0) }
        let p = other.flatMap { model.people[$0] }
        return Button { model.env.router.open(.thread(t.id)) } label: {
            Row(Text(verbatim: p?.displayName ?? "Driver"),
                subtitle: Text(verbatim: t.lastMessage?.body ?? (t.kind == .listing ? "About a listing" : "")),
                leading: {
                    Avatar(name: p?.displayName ?? "", url: p?.avatarPath.map { model.env.media.publicURL(bucket: .avatars, path: $0) }, size: .s40)
                        .overlay(alignment: .bottomTrailing) {
                            if t.kind == .listing { Image(systemName: "tag.fill").font(.caption2).foregroundStyle(Color.sodium) }
                        }
                }, trailing: {
                    if request, let other {
                        HStack {
                            QuietButton("Accept") { Task { try? await model.env.friends.sendRequest(to: other); await model.load() } }
                            QuietButton("Block") { Task { try? await model.env.safety.block(other); await model.load() } }
                        }
                    } else if let d = t.lastMessage?.createdAt {
                        Text(verbatim: d.formatted(.relative(presentation: .numeric))).typeStyle(.foot)
                    }
                })
        }
        .buttonStyle(RowButtonStyle())
    }
}

struct TeamIcon: View {
    let team: Team
    let env: AppEnvironment
    let size: CGFloat
    var selected = false
    var body: some View {
        Group {
            if let path = team.iconPath {
                MediaView(url: env.media.publicURL(bucket: .teams, path: path), aspectRatio: 1, cornerRadius: Radius.r12, label: Text(verbatim: team.name))
            } else {
                Text(verbatim: String(team.tag.prefix(2))).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                    .frame(width: size, height: size)
                    .background(Color.curb, in: RoundedRectangle(cornerRadius: Radius.r12))
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: Radius.r12).strokeBorder(selected ? Color.sodium : .clear, lineWidth: Size.Marker.ring))
        .accessibilityLabel(Text(verbatim: team.name))
    }
}

// MARK: T4

struct FindOrStart: View {
    let model: TeamsModel
    @State var code: String
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var results: [Team] = []
    @State private var name = ""
    @State private var tag = ""
    @State private var about = ""
    @State private var isPublic = true
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Sheet(Text(mode == 0 ? "Find a team" : "Start a team")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    SegmentedSwitch(selection: $mode, options: [(0, "Find"), (1, "Start")])
                    if mode == 0 { find } else { start }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
        .task(id: code) {
            try? await Task.sleep(for: .milliseconds(250))
            results = (try? await model.env.teams.publicTeams(matching: code)) ?? []
        }
    }

    private var find: some View {
        VStack(alignment: .leading, spacing: 0) {
            Field("Search", text: $code, prompt: "Search teams or paste an invite").textInputAutocapitalization(.never)
            if code.count >= 6 && !code.contains(" ") {
                SecondaryButton("Join with this invite") {
                    run {
                        let t = try await model.env.teams.join(code: code)
                        dismiss()
                        model.env.router.open(.team(t.id))
                    }
                }
                .padding(.vertical, Space.s8)
            }
            ForEach(results) { t in
                Row(Text(verbatim: t.name), subtitle: Text(verbatim: "\(t.tag) · \(t.memberCount) members\(t.about.isEmpty ? "" : " · \(t.about)")"),
                    leading: { TeamIcon(team: t, env: model.env, size: Size.hitTarget) },
                    trailing: {
                        SecondaryButton("Join") { run { try await model.env.teams.joinPublic(t.id); dismiss() } }.frame(width: Size.row * 1.4)
                    })
            }
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Field("Name", text: $name, limit: 40)
            Field("Tag", text: $tag, prompt: "2–5 letters", limit: 5)
                .textInputAutocapitalization(.characters)
                .onChange(of: tag) { tag = String(tag.uppercased().filter(\.isLetter).prefix(5)) }
            Field("About", text: $about, limit: 300, axis: .vertical)
            Row(Text("Anyone can find and join"), showsDivider: false, trailing: { Toggle("", isOn: $isPublic).labelsHidden().tint(.sodium) })
            PrimaryButton("Start team", isLoading: working) {
                run {
                    let t = try await model.env.teams.createTeam(TeamDraft(name: name, tag: tag, about: about, isPublic: isPublic))
                    await model.load()
                    model.selected = t.id
                    dismiss()
                    if let general = try? await model.env.teams.channels(of: t.id).first(where: { $0.kind == .text }) {
                        model.env.router.open(.channel(general.id))
                    }
                }
            }
            .disabled(name.isEmpty || tag.count < 2)
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await body() } catch WaypointsError.conflict {
                error = "That tag is taken."
            } catch WaypointsError.notFound {
                error = "No team with that invite."
            } catch {
                self.error = "Couldn't do that. Check your connection and try again."
            }
            working = false
        }
    }
}

// MARK: T5 Team, T6 Members

struct TeamDetail: View {
    let model: TeamsModel
    let teamID: TeamID
    @State private var team: Team?
    @State private var perms: TeamPermissions = []
    @State private var roles: [TeamRole] = []
    @State private var confirmLeave = false
    @State private var typed = ""
    @State private var newChannel = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            if let t = team {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        TeamIcon(team: t, env: model.env, size: 96)
                        Text(verbatim: t.name).typeStyle(.title).foregroundStyle(Color.chalk)
                        Text(verbatim: t.tag).typeStyle(.readoutS).foregroundStyle(Color.sodium)
                        if !t.about.isEmpty { Text(verbatim: t.about).typeStyle(.body).foregroundStyle(Color.chalk) }
                        Text("\(t.memberCount) members").typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    .padding(Space.margin)
                    if let code = t.inviteCode, let url = URL(string: "waypoints://invite/team/\(code)") {
                        ShareLink(item: url) { Row(Text("Invite people"), trailing: { Image.symbol(Symbol.share) }) }
                    }
                    NavigationLink { MembersView(model: model, teamID: teamID, perms: perms, roles: roles) } label: {
                        Row(Text("Members"), trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                    if perms.contains(.manageChannels) {
                        SectionLabel("CHANNELS")
                        ForEach(model.channels) { c in
                            Row(Text(verbatim: c.kind == .text ? "# \(c.name)" : c.name))
                                .contextMenu {
                                    Button("Delete", role: .destructive) {
                                        Task { try? await model.env.teams.deleteChannel(c.id); await model.loadTeam() }
                                    }
                                }
                        }
                        HStack {
                            Field("New channel", text: $newChannel, prompt: "lowercase-with-hyphens", limit: 30)
                                .textInputAutocapitalization(.never)
                            SecondaryButton("Add") {
                                let name = newChannel.lowercased().replacingOccurrences(of: " ", with: "-")
                                newChannel = ""
                                Task {
                                    _ = try? await model.env.teams.saveChannel(Channel(teamID: teamID, name: name, kind: .text, sort: model.channels.count))
                                    await model.loadTeam()
                                }
                            }
                            .frame(width: Size.row * 1.4)
                        }
                        .padding(.horizontal, Space.margin)
                    }
                    if perms.contains(.manageRoles) {
                        SectionLabel("ROLES")
                        ForEach(roles) { r in
                            Row(Text(verbatim: r.name), subtitle: Text(verbatim: describe(r.permissions)), leading: {
                                Circle().fill(r.colorHex.flatMap { Color(paintHex: $0) } ?? .dust).frame(width: Space.s12, height: Space.s12)
                            })
                        }
                    }
                    VStack(spacing: Space.s12) {
                        if t.ownerID == model.me {
                            Field("Type the team name to delete it", text: $typed)
                            DestructiveButton("Delete team", confirmTitle: "Delete team", consequence: "Channels, roles, and messages are deleted.") {
                                Task { try? await model.env.teams.deleteTeam(teamID); model.selected = nil; await model.load(); dismiss() }
                            }
                            .disabled(typed != t.name)
                        } else {
                            DestructiveButton("Leave team", confirmTitle: "Leave team", consequence: "You'll need an invite to come back to a private team.") {
                                Task { try? await model.env.teams.leave(teamID); model.selected = nil; await model.load(); dismiss() }
                            }
                        }
                    }
                    .padding(Space.margin)
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task {
            team = try? await model.env.teams.team(teamID)
            perms = (try? await model.env.teams.myPermissions(in: teamID)) ?? []
            roles = (try? await model.env.teams.roles(of: teamID)) ?? []
        }
    }

    private func describe(_ p: TeamPermissions) -> String {
        let names: [(TeamPermissions, String)] = [(.manageTeam, "team"), (.manageChannels, "channels"), (.manageRoles, "roles"),
                                                  (.kick, "kick"), (.deleteMessages, "delete messages"), (.hostMeets, "host meets")]
        let list = names.filter { p.contains($0.0) }.map(\.1)
        return list.isEmpty ? "No permissions" : list.joined(separator: ", ")
    }
}

struct MembersView: View {
    let model: TeamsModel
    let teamID: TeamID
    let perms: TeamPermissions
    let roles: [TeamRole]
    @State private var members: [TeamMember] = []
    @State private var profiles: [UserID: Profile] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(roles) { role in
                    let inRole = members.filter { $0.roleID == role.id }
                    if !inRole.isEmpty {
                        SectionLabel(verbatim: role.name.uppercased())
                        ForEach(inRole, id: \.userID) { m in row(m) }
                    }
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Members")
        .task { await load() }
    }

    private func row(_ m: TeamMember) -> some View {
        let p = profiles[m.userID]
        return Button { model.env.router.open(.profile(m.userID)) } label: {
            Row(Text(verbatim: p?.displayName ?? ""), subtitle: p.map { Text(verbatim: "@\($0.handle)") }, leading: {
                Avatar(name: p?.displayName ?? "", size: .s40)
            })
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu {
            if perms.contains(.manageRoles) {
                ForEach(roles) { r in
                    Button("Make \(r.name)") { Task { try? await model.env.teams.assign(r.id, to: m.userID, in: teamID); await load() } }
                }
            }
            if perms.contains(.kick) && m.userID != model.me {
                Button("Remove", role: .destructive) { Task { try? await model.env.teams.kick(m.userID, from: teamID); await load() } }
            }
        }
    }

    private func load() async {
        members = (try? await model.env.teams.members(of: teamID)) ?? []
        for p in (try? await model.env.profiles.profiles(members.map(\.userID))) ?? [] { profiles[p.userID] = p }
    }
}
