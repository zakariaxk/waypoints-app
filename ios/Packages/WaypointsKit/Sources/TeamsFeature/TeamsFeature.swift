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
        registry.registerDebugScreen("standings") { AnyView(NavigationStack { StandingsView(model: model) }) }
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
    var channelUnread: [ChannelID: Int] = [:]
    /// TEAM-4: who is in each voice channel of the selected team.
    var occupants: [ChannelID: [VoiceOccupant]] = [:]
    var unread = 0
    /// SAFE-12: active mutes and per-channel unread for every team (badge exclusion).
    var mutes: Set<MuteTarget> = []
    var allChannelUnread: [ChannelID: Int] = [:]
    var me: UserID?
    var loaded = false
    var failed = false
    var error: String?

    init(env: AppEnvironment, registry: FeatureRegistry) { self.env = env; self.registry = registry }

    func start() {
        let env = self.env
        Task { [weak self] in
            for await n in await env.messages.unreadCount() { self?.unread = n }
        }
    }

    func load() async {
        me = await env.auth.currentSession()?.userID
        let mine = try? await env.teams.myTeams()
        failed = mine == nil && teams.isEmpty
        if let mine { teams = mine }
        if let found = try? await env.messages.threads() { threads = found }
        await refreshMutes()
        friends = Set(((try? await env.friends.friends()) ?? []).map(\.id))
        if let me {
            for p in (try? await env.profiles.profiles(threads.map { $0.other(than: me) })) ?? [] { people[p.userID] = p }
        }
        if selected == nil { selected = teams.first?.id }
        await loadTeam()
        loaded = true
    }

    /// SAFE-12: the badge counts nothing from muted threads, people, channels, or teams.
    var badgeUnread: Int { max(0, unread - mutedUnread) }

    private var mutedUnread: Int {
        guard let me else { return 0 }
        var n = 0
        for t in threads where t.unreadCount > 0 {
            if mutes.contains(.thread(t.id)) || mutes.contains(.user(t.other(than: me))) {
                n += t.unreadCount
            }
        }
        for (c, count) in allChannelUnread where mutes.contains(.channel(c)) {
            n += count
        }
        return n
    }

    func isMuted(_ target: MuteTarget) -> Bool { mutes.contains(target) }

    /// Loads mutes and the unread of every text channel I belong to (one RPC).
    func refreshMutes() async {
        mutes = (try? await env.messages.mutes()) ?? mutes
        var chans: [ChannelID] = []
        for t in teams {
            chans += ((try? await env.teams.channels(of: t.id)) ?? []).filter { $0.kind == .text }.map(\.id)
        }
        allChannelUnread = (try? await env.messages.unreadCounts(in: chans)) ?? [:]
    }

    /// Returns false and shows the error line on failure.
    func setMute(_ target: MuteTarget, _ duration: MuteDuration?) async -> Bool {
        do {
            try await env.messages.setMute(target, for: duration)
            await refreshMutes()
            return true
        } catch {
            self.error = String(localized: "Couldn't update mute. Check your connection and try again.", bundle: .module)
            return false
        }
    }

    func loadTeam() async {
        guard let id = selected else { channels = []; upcoming = nil; channelUnread = [:]; return }
        channels = (try? await env.teams.channels(of: id)) ?? []
        channelUnread = (try? await env.messages.unreadCounts(in: channels.filter { $0.kind == .text }.map(\.id))) ?? [:]
        upcoming = (try? await env.teams.meets(of: id))?.first
        if upcoming == nil, let me {
            upcoming = (try? await env.meets.upcomingMeets(for: me))?.first { $0.teamID == id }
        }
        await loadOccupants()
    }

    /// TEAM-4: refreshed on appear and every 20 s while T1 is visible.
    func loadOccupants() async {
        let voice = channels.filter { $0.kind == .voice }.map(\.id)
        guard !voice.isEmpty else { occupants = [:]; return }
        if let found = try? await env.gateway.voiceOccupants(voice) { occupants = found }
    }
}

// MARK: T1

/// SAFE-12: which mute a dialog is editing.
struct MutePrompt: Identifiable {
    let target: MuteTarget
    let name: String
    var id: String {
        switch target {
        case let .user(id): "u\(id.raw)"
        case let .thread(id): "t\(id.raw)"
        case let .channel(id): "c\(id.raw)"
        case let .team(id): "m\(id.raw)"
        }
    }
}

func muteDurationTitle(_ d: MuteDuration) -> LocalizedStringKey {
    switch d {
    case .eightHours: "8 hours"
    case .week: "1 week"
    case .untilTurnedOn: "Until turned back on"
    }
}

/// The mute dialog shared by T1 rows and T4/T5: durations, or Unmute when active.
@MainActor
@ViewBuilder
func muteDialog(_ prompt: MutePrompt?, model: TeamsModel, dismiss: @escaping () -> Void) -> some View {
    if let prompt, model.isMuted(prompt.target) {
        Button {
            dismiss()
            Task { await model.setMute(prompt.target, nil) }
        } label: { Text("Unmute", bundle: .module) }
    } else if let prompt {
        ForEach(MuteDuration.allCases, id: \.self) { duration in
            Button {
                dismiss()
                Task { await model.setMute(prompt.target, duration) }
            } label: { Text(muteDurationTitle(duration), bundle: .module) }
        }
    }
    Button("Cancel", role: .cancel) { dismiss() }
}

struct TeamsHome: View {
    @Bindable var model: TeamsModel
    @State private var dms = false
    @State private var showFind = false
    @State private var showStandings = false
    @State private var mutePrompt: MutePrompt?

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Color.seam).frame(width: Size.Marker.innerStroke)
            ScrollView {
                if !model.loaded {
                    SkeletonRow(); SkeletonRow(); SkeletonRow()
                } else if dms || model.teams.isEmpty && !model.threads.isEmpty {
                    directMessages
                } else if let team = model.teams.first(where: { $0.id == model.selected }) {
                    teamPane(team)
                } else if model.failed {
                    ErrorState(Text("Couldn't load your teams. Check your connection and try again.", bundle: .module)) { Task { await model.load() } }
                } else {
                    VStack(alignment: .leading, spacing: Space.s16) {
                        Text("Teams are where your people talk. Join one or start your own.", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
                        PrimaryButton("Find a team") { showFind = true }
                        SecondaryButton("Start a team") { showFind = true }
                    }
                    .padding(Space.margin)
                }
            }
            .refreshable { await model.load() }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(Text("Teams", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { IconButton("list.number", label: "Standings") { showStandings = true } }
        }
        .navigationDestination(isPresented: $showStandings) { StandingsView(model: model) }
        .sheet(isPresented: $showFind, onDismiss: { Task { await model.load() } }) { FindOrStart(model: model, code: "") }
        .confirmationDialog("Mute", isPresented: Binding(
            get: { mutePrompt != nil }, set: { if !$0 { mutePrompt = nil } }), titleVisibility: .visible) {
            muteDialog(mutePrompt, model: model) { mutePrompt = nil }
        } message: {
            if let prompt = mutePrompt { Text(verbatim: prompt.name) }
        }
        .task { await model.load() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                await model.loadOccupants()
            }
        }
    }

    private var rail: some View {
        ScrollView {
            VStack(spacing: Space.s12) {
                Button { dms = true } label: {
                    Image.symbol("bubble.left.and.bubble.right").imageScale(.large)
                        .foregroundStyle(dms ? Color.sodium : Color.chalk)
                        .frame(width: Size.hitTarget, height: Size.hitTarget)
                        .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12))
                        .overlay(alignment: .topTrailing) {
                            if model.badgeUnread > 0 {
                                Text(verbatim: "\(model.badgeUnread)").typeStyle(.readoutS).foregroundStyle(Color.sodium)
                                    .padding(.horizontal, Space.s4).background(Color.sodiumDim, in: RoundedRectangle(cornerRadius: Radius.r6))
                            }
                        }
                }
                .accessibilityLabel(Text("Direct messages", bundle: .module))
                .accessibilityValue(model.badgeUnread > 0 ? Text("\(model.badgeUnread) unread", bundle: .module) : Text(verbatim: ""))
                .accessibilityAddTraits(dms ? .isSelected : [])
                .buttonStyle(PressScaleStyle())
                Hairline().frame(width: Size.hitTarget)
                ForEach(model.teams) { t in
                    Button {
                        dms = false
                        model.selected = t.id
                        Task { await model.loadTeam() }
                    } label: { TeamIcon(team: t, env: model.env, size: Size.hitTarget, selected: !dms && model.selected == t.id) }
                    .buttonStyle(PressScaleStyle())
                }
                IconButton(Symbol.add, label: "Find or start a team") { showFind = true }
            }
            .padding(.vertical, Space.s12)
        }
        .scrollIndicators(.hidden)
        .frame(width: Size.hitTarget + Space.s20)
        .background(Color.tarmac)
    }

    private func teamPane(_ team: Team) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.env.router.open(.team(team.id)) } label: {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(verbatim: team.name).typeStyle(.title).foregroundStyle(Color.chalk).multilineTextAlignment(.leading)
                    HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                        Text(verbatim: team.tag).typeStyle(.readoutS).foregroundStyle(Color.sodium)
                        Text("\(team.memberCount) members", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], Space.margin)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleStyle())
            SectionLabel("TEXT")
            ForEach(model.channels.filter { $0.kind == .text }) { c in
                let muted = model.isMuted(.channel(c.id))
                Button { model.env.router.open(.channel(c.id)) } label: {
                    Row(Text(verbatim: "# \(c.name)").fontWeight(!muted && (model.channelUnread[c.id] ?? 0) > 0 ? nil : .regular), trailing: {
                        HStack(spacing: Space.s8) {
                            if muted {
                                Image.symbol("bell.slash").imageScale(.small).foregroundStyle(Color.dust)
                                    .accessibilityLabel(Text("Muted", bundle: .module))
                            } else if let n = model.channelUnread[c.id] {
                                Text(verbatim: n > 98 ? "99+" : "\(n)").typeStyle(.readoutS).foregroundStyle(Color.chalk)
                            }
                        }
                    })
                }
                .buttonStyle(RowButtonStyle())
                .contextMenu {
                    Button { mutePrompt = MutePrompt(target: .channel(c.id), name: "#\(c.name)") }
                    label: {
                        if muted { Text("Unmute", bundle: .module) } else { Text("Mute", bundle: .module) }
                    }
                }
            }
            let voice = model.channels.filter { $0.kind == .voice }
            if !voice.isEmpty && model.registry.canOpen(.voice(voice[0].id)) {
                SectionLabel("VOICE")
                ForEach(voice) { c in
                    Button { model.env.router.open(.voice(c.id)) } label: {
                        Row(Text(verbatim: c.name), leading: { Image.symbol(Symbol.speaker).foregroundStyle(Color.dust) },
                            trailing: { occupantStack(model.occupants[c.id] ?? []) })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            if let m = model.upcoming {
                SectionLabel("UPCOMING")
                Button { model.env.router.open(.meet(m.id)) } label: {
                    Row(Text(verbatim: m.title), subtitle: m.placeName.isEmpty ? nil : Text(verbatim: m.placeName), trailing: {
                        Text(readout: m.startsAt.formatted(date: .abbreviated, time: .shortened), token: .readoutS)
                    })
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    /// TEAM-4: up to 4 avatars of who is in the channel, then "+N".
    @ViewBuilder
    private func occupantStack(_ list: [VoiceOccupant]) -> some View {
        if !list.isEmpty {
            HStack(spacing: -Space.s8) {
                ForEach(list.prefix(4)) { o in
                    let p = UserID(string: o.userID).flatMap { model.people[$0] }
                    Avatar(name: p?.displayName ?? o.name,
                           url: p?.avatarPath.map { model.env.media.publicURL(bucket: .avatars, path: $0) }, size: .s28)
                }
                if list.count > 4 {
                    Text(verbatim: "+\(list.count - 4)").typeStyle(.readoutS).foregroundStyle(Color.dust)
                        .padding(.leading, Space.s12)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(list.count) in voice", bundle: .module))
        }
    }

    private var directMessages: some View {
        let requests = model.threads.filter { t in model.me.map { !model.friends.contains(t.other(than: $0)) && t.kind == .dm && t.lastMessage?.authorID != $0 } ?? false }
        let rest = model.threads.filter { t in !requests.contains(t) }
        return VStack(alignment: .leading, spacing: 0) {
            if model.threads.isEmpty {
                Text("No messages yet.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
            }
            if let error = model.error {
                Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin)
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
        // SAFE-12: muted thread or muted person: no unread badge, small muted glyph.
        let muted = model.isMuted(.thread(t.id)) || (other.map { model.isMuted(.user($0)) } ?? false)
        return Button { model.env.router.open(.thread(t.id)) } label: {
            Row(Text(verbatim: p?.displayName ?? "Driver"),
                subtitle: Text(verbatim: t.lastMessage?.body ?? (t.kind == .listing ? "About a listing" : "")),
                leading: {
                    Avatar(name: p?.displayName ?? "", url: p?.avatarPath.map { model.env.media.publicURL(bucket: .avatars, path: $0) }, size: .s40)
                        .overlay(alignment: .bottomTrailing) {
                            if t.kind == .listing {
                                Image.symbol(Symbol.market).symbolVariant(.fill).imageScale(.small).foregroundStyle(Color.sodium)
                                    .accessibilityLabel(Text("Listing", bundle: .module))
                            }
                        }
                }, trailing: {
                    if request, let other {
                        HStack {
                            QuietButton("Accept") { answer { try await model.env.friends.sendRequest(to: other) } }
                            QuietButton("Block") { answer { try await model.env.safety.block(other) } }
                        }
                    } else if let d = t.lastMessage?.createdAt {
                        VStack(alignment: .trailing, spacing: Space.s2) {
                            Text(verbatim: d.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))).typeStyle(.foot)
                            if muted {
                                Image.symbol("bell.slash").imageScale(.small).foregroundStyle(Color.dust)
                                    .accessibilityLabel(Text("Muted", bundle: .module))
                            } else if t.unreadCount > 0 {
                                Text(verbatim: "\(t.unreadCount)").typeStyle(.readoutS).foregroundStyle(Color.sodium)
                            }
                        }
                    }
                })
                .lineLimit(2)
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu {
            if let other {
                Button { mutePrompt = MutePrompt(target: .user(other), name: p?.displayName ?? "") }
                label: {
                    if model.isMuted(.user(other)) { Text("Unmute", bundle: .module) }
                    else { Text("Mute", bundle: .module) + Text(verbatim: " \(p?.displayName ?? "")") }
                }
            }
            Button { mutePrompt = MutePrompt(target: .thread(t.id), name: p?.displayName ?? "") }
            label: {
                if model.isMuted(.thread(t.id)) { Text("Unmute", bundle: .module) }
                else { Text("Mute conversation", bundle: .module) }
            }
        }
    }

    private func answer(_ body: @escaping () async throws -> Void) {
        model.error = nil
        Task {
            do { try await body() } catch {
                model.error = String(localized: "Couldn't do that. Check your connection and try again.", bundle: .module)
            }
            await model.load()
        }
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
    @State private var photo: PhotosPickerItem?
    @State private var iconPath: String?
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
                        SecondaryButton("Join") { run { try await model.env.teams.joinPublic(t.id); dismiss() } }.frame(width: Size.wideButton)
                    })
            }
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            IconPicker(model: model, team: Team(ownerID: model.me ?? UserID(), name: name, tag: tag.isEmpty ? "?" : tag, iconPath: iconPath),
                       photo: $photo, iconPath: $iconPath)
            Field("Name", text: $name, limit: 40)
            Field("Tag", text: $tag, prompt: "2–5 letters", limit: 5)
                .textInputAutocapitalization(.characters)
                .onChange(of: tag) { tag = String(tag.uppercased().filter(\.isLetter).prefix(5)) }
            Field("About", text: $about, limit: 300, axis: .vertical)
            Row(Text("Anyone can find and join", bundle: .module), showsDivider: false, trailing: { Toggle("", isOn: $isPublic).labelsHidden().tint(.sodium) })
            PrimaryButton("Start team", isLoading: working) {
                run {
                    // SAFE-4: same client-side word check as posts, listings, and messages.
                    if case .blocked = await model.env.safety.check(name + " " + tag + " " + about) {
                        self.error = String(localized: "That team can't be created.", bundle: .module)
                        return
                    }
                    let t = try await model.env.teams.createTeam(TeamDraft(name: name, tag: tag, about: about, iconPath: iconPath, isPublic: isPublic))
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
        guard !working else { return }
        working = true
        error = nil
        Task {
            do { try await body() } catch WaypointsError.rateLimited {
                error = String(localized: "You're doing that a lot. Try again in a few minutes.", bundle: .module)
            } catch WaypointsError.conflict {
                error = String(localized: "That tag is taken.", bundle: .module)
            } catch WaypointsError.notFound {
                error = String(localized: "No team with that invite.", bundle: .module)
            } catch {
                self.error = String(localized: "Couldn't do that. Check your connection and try again.", bundle: .module)
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
    @State private var typed = ""
    @State private var newChannel = ""
    @State private var renaming: Channel?
    @State private var renameText = ""
    @State private var editingRole: TeamRole?
    @State private var editingTeam = false
    @State private var error: String?
    @State private var failed = false
    @State private var standings: [TeamStanding]?
    @State private var standingsFailed = false
    @State private var mutePrompt: MutePrompt?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            if let t = team {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        TeamIcon(team: t, env: model.env, size: Avatar.Diameter.s96.rawValue)
                        Text(verbatim: t.name).typeStyle(.title).foregroundStyle(Color.chalk)
                        Text(verbatim: t.tag).typeStyle(.readoutS).foregroundStyle(Color.sodium)
                        if !t.about.isEmpty { Text(verbatim: t.about).typeStyle(.body).foregroundStyle(Color.chalk) }
                        Text("\(t.memberCount) members", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    .padding(Space.margin)
                    NavigationLink { StandingsView(model: model) } label: {
                        Row(Text("Showdown votes this week", bundle: .module), subtitle: standingNote, trailing: {
                            if let s = standings?.first(where: { $0.id == teamID }) {
                                Text(verbatim: "\(s.score)").typeStyle(.readoutS).foregroundStyle(Color.chalk)
                            }
                            Disclosure()
                        })
                    }
                    .buttonStyle(RowButtonStyle())
                    if let code = t.inviteCode, let url = Route.joinTeam(code: code).shareURL {
                        NavigationLink {
                            QRCodeScreen(Text("Invite people", bundle: .module), heading: Text(verbatim: t.name),
                                         caption: Text("Scan to join, or share the link.", bundle: .module), url: url)
                        } label: { Row(Text("Invite people", bundle: .module), trailing: { Disclosure() }) }
                        .buttonStyle(RowButtonStyle())
                    }
                    NavigationLink { MembersView(model: model, teamID: teamID, ownerID: t.ownerID, perms: perms, roles: roles) } label: {
                        Row(Text("Members", bundle: .module), trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                    NavigationLink { TeamMeets(model: model, teamID: teamID) } label: {
                        Row(Text("Meets", bundle: .module), trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                    if perms.contains(.manageTeam) {
                        Button { editingTeam = true } label: { Row(Text("Edit team", bundle: .module), trailing: { Disclosure() }) }
                            .buttonStyle(RowButtonStyle())
                    }
                    // SAFE-12: muting the team silences its channels' pushes and badge.
                    Button { mutePrompt = MutePrompt(target: .team(teamID), name: t.name) } label: {
                        Row(Text("Mute team", bundle: .module), trailing: {
                            if model.isMuted(.team(teamID)) {
                                Image.symbol("bell.slash").imageScale(.small).foregroundStyle(Color.dust)
                                    .accessibilityLabel(Text("Muted", bundle: .module))
                            } else { Disclosure() }
                        })
                    }
                    .buttonStyle(RowButtonStyle())
                    // SAFE-1: a team can be reported; its owner is not the viewer's own team.
                    if t.ownerID != model.me {
                        Button { model.env.router.open(.reportContent(ContentRef(kind: .team, id: teamID.description))) } label: {
                            Row(Text("Report team", bundle: .module), trailing: { Disclosure() })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                    if perms.contains(.manageChannels) { channelsSection }
                    if perms.contains(.manageRoles) { rolesSection }
                    VStack(spacing: Space.s12) {
                        if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                        if t.ownerID == model.me {
                            Field("Type the team name to delete it", text: $typed)
                            DestructiveButton("Delete team", confirmTitle: "Delete team", consequence: "Channels, roles, and messages are deleted.") {
                                act { try await model.env.teams.deleteTeam(teamID); model.selected = nil; await model.load(); dismiss() }
                            }
                            .disabled(typed != t.name)
                        } else {
                            DestructiveButton("Leave team", confirmTitle: "Leave team", consequence: "You'll need an invite to come back to a private team.") {
                                act { try await model.env.teams.leave(teamID); model.selected = nil; await model.load(); dismiss() }
                            }
                        }
                    }
                    .padding(Space.margin)
                }
            } else if failed {
                ErrorState(Text("Couldn't load this team. Check your connection and try again.", bundle: .module)) { Task { await reload() } }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename channel", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText).textInputAutocapitalization(.never)
            Button("Rename") { if let c = renaming { rename(c) } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(item: $editingRole, onDismiss: { Task { await reload() } }) { r in
            RoleEditor(model: model, role: r, isTop: r.id == roles.first?.id)
        }
        .sheet(isPresented: $editingTeam) {
            if let t = team {
                EditTeam(model: model, team: t) { saved in
                    team = saved
                    Task { await model.load() }
                }
            }
        }
        .task { await reload() }
        .confirmationDialog("Mute", isPresented: Binding(
            get: { mutePrompt != nil }, set: { if !$0 { mutePrompt = nil } }), titleVisibility: .visible) {
            muteDialog(mutePrompt, model: model) { mutePrompt = nil }
        } message: {
            if let prompt = mutePrompt { Text(verbatim: prompt.name) }
        }
    }

    /// TEAM-11: the team's rank this week; nothing while loading.
    private var standingNote: Text? {
        if standingsFailed { return Text("Couldn't load the standings.", bundle: .module) }
        guard let standings else { return nil }
        guard let s = standings.first(where: { $0.id == teamID }) else { return Text("No votes yet this week.", bundle: .module) }
        return Text("Rank \(s.rank)", bundle: .module)
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("CHANNELS")
            ForEach(model.channels) { c in
                let muted = model.isMuted(.channel(c.id))
                Row(Text(verbatim: c.kind == .text ? "# \(c.name)" : c.name), trailing: {
                    HStack(spacing: Space.s8) {
                        if muted {
                            Image.symbol("bell.slash").imageScale(.small).foregroundStyle(Color.dust)
                                .accessibilityLabel(Text("Muted", bundle: .module))
                        }
                        Image.symbol(Symbol.more).accessibilityHidden(true)
                    }
                })
                .contextMenu {
                    Button { mutePrompt = MutePrompt(target: .channel(c.id), name: c.name) }
                    label: {
                        if muted { Text("Unmute", bundle: .module) } else { Text("Mute", bundle: .module) }
                    }
                    Button("Rename") { renameText = c.name; renaming = c }
                    if c.id != model.channels.first?.id { Button("Move up") { move(c, by: -1) } }
                    if c.id != model.channels.last?.id { Button("Move down") { move(c, by: 1) } }
                    Button("Delete", role: .destructive) {
                        act { try await model.env.teams.deleteChannel(c.id) }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: Space.s12) {
                Field("New channel", text: $newChannel, prompt: "lowercase-with-hyphens", limit: 30)
                    .textInputAutocapitalization(.never)
                SecondaryButton("Add") {
                    let name = slug(newChannel)
                    newChannel = ""
                    guard !name.isEmpty else { return }
                    act { try await model.env.teams.saveChannel(Channel(teamID: teamID, name: name, kind: .text, sort: model.channels.count)) }
                }
                .frame(width: Size.wideButton)
            }
            .padding(.horizontal, Space.margin)
        }
    }

    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("ROLES")
            ForEach(roles) { r in
                Button { editingRole = r } label: {
                    Row(Text(verbatim: r.name), subtitle: Text(verbatim: describe(r.permissions)), leading: {
                        Circle().fill(r.colorHex.flatMap { Color(paintHex: $0) } ?? .dust).frame(width: Space.s12, height: Space.s12)
                    }, trailing: { Disclosure() })
                }
                .buttonStyle(RowButtonStyle())
            }
            Button {
                let rank = min(99, (roles.filter { $0.rank < 100 }.map(\.rank).max() ?? 0) + 10)
                editingRole = TeamRole(teamID: teamID, name: "", rank: rank, permissions: [])
            } label: {
                Row(Text("Add role", bundle: .module), leading: { Image.symbol(Symbol.add).foregroundStyle(Color.sodium) })
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func reload() async {
        failed = false
        guard let found = try? await model.env.teams.team(teamID) else { failed = team == nil; return }
        team = found
        if model.selected != teamID {
            model.selected = teamID
            await model.loadTeam()
        }
        perms = (try? await model.env.teams.myPermissions(in: teamID)) ?? []
        roles = (try? await model.env.teams.roles(of: teamID)) ?? []
        let ranks = try? await model.env.teams.standings(including: teamID)
        if let ranks { standings = ranks }
        standingsFailed = ranks == nil
    }

    private func act(_ body: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await body() } catch {
                self.error = String(localized: "Couldn't do that. Check your connection and try again.", bundle: .module)
            }
            await model.loadTeam()
        }
    }

    private func slug(_ s: String) -> String {
        String(s.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-").prefix(30))
    }

    private func rename(_ c: Channel) {
        var c = c
        c.name = slug(renameText)
        renaming = nil
        guard !c.name.isEmpty else { return }
        let renamed = c
        act { try await model.env.teams.saveChannel(renamed) }
    }

    private func move(_ c: Channel, by offset: Int) {
        var list = model.channels
        guard let i = list.firstIndex(of: c), list.indices.contains(i + offset) else { return }
        list.swapAt(i, i + offset)
        let order = list
        act {
            for (n, ch) in order.enumerated() where ch.sort != n {
                var updated = ch
                updated.sort = n
                try await model.env.teams.saveChannel(updated)
            }
        }
    }

    private func describe(_ p: TeamPermissions) -> String {
        let names: [(TeamPermissions, String)] = [(.manageTeam, "team"), (.manageChannels, "channels"), (.manageRoles, "roles"),
                                                  (.kick, "kick"), (.deleteMessages, "delete messages"), (.hostMeets, "host meets")]
        let list = names.filter { p.contains($0.0) }.map(\.1)
        return list.isEmpty ? "No permissions" : list.joined(separator: ", ")
    }
}

/// Picks a photo for a team icon and uploads it to the `teams` bucket (T4, T5 "Edit team").
struct IconPicker: View {
    let model: TeamsModel
    let team: Team
    @Binding var photo: PhotosPickerItem?
    @Binding var iconPath: String?
    @State private var uploading = false
    @State private var failed = false
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: Space.s12) {
                TeamIcon(team: team, env: model.env, size: Size.row)
                Text(uploading ? "Uploading" : failed ? "Couldn't upload. Try again." : (iconPath == nil ? "Add icon" : "Change icon"))
                    .typeStyle(.bodyStrong).foregroundStyle(Color.sodium)
            }
        }
        .buttonStyle(PressScaleStyle())
        .photosPicker(isPresented: $picking, selection: $photo, matching: .images)
        .disabled(uploading)
        .onChange(of: photo) {
            guard let photo else { return }
            uploading = true
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self),
                   let media = try? await model.env.media.upload(data, contentType: "image/jpeg", to: .teams, progress: { _ in }) {
                    iconPath = media.path
                    failed = false
                } else {
                    failed = true
                }
                uploading = false
                self.photo = nil
            }
        }
    }
}

/// T5 "Edit team": icon, name, about, and whether anyone can find it. Needs manage team.
struct EditTeam: View {
    let model: TeamsModel
    let team: Team
    let onSave: (Team) -> Void
    @State private var name: String
    @State private var about: String
    @State private var isPublic: Bool
    @State private var iconPath: String?
    @State private var photo: PhotosPickerItem?
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: TeamsModel, team: Team, onSave: @escaping (Team) -> Void) {
        self.model = model
        self.team = team
        self.onSave = onSave
        _name = State(initialValue: team.name)
        _about = State(initialValue: team.about)
        _isPublic = State(initialValue: team.isPublic)
        _iconPath = State(initialValue: team.iconPath)
    }

    private var draft: Team {
        var t = team
        t.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        t.about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        t.isPublic = isPublic
        t.iconPath = iconPath
        return t
    }

    var body: some View {
        Sheet(Text("Edit team", bundle: .module)) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    IconPicker(model: model, team: draft, photo: $photo, iconPath: $iconPath)
                    Field("Name", text: $name, limit: 40)
                    Field("About", text: $about, limit: 300, axis: .vertical)
                    Row(Text("Anyone can find and join", bundle: .module), showsDivider: false, trailing: { Toggle("", isOn: $isPublic).labelsHidden().tint(.sodium) })
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Save", isLoading: working) {
                        working = true
                        error = nil
                        let t = draft
                        Task {
                            // SAFE-4: same client-side word check as posts, listings, and messages.
                            if case .blocked = await model.env.safety.check(t.name + " " + t.about) {
                                self.error = String(localized: "That team can't be saved.", bundle: .module)
                                working = false
                                return
                            }
                            do {
                                let saved = try await model.env.teams.updateTeam(t)
                                onSave(saved)
                                dismiss()
                            } catch WaypointsError.rateLimited {
                                self.error = String(localized: "You're doing that a lot. Try again in a few minutes.", bundle: .module)
                            } catch {
                                self.error = String(localized: "Couldn't save. Check your connection and try again.", bundle: .module)
                            }
                            working = false
                        }
                    }
                    .disabled(draft.name.isEmpty)
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
    }
}

/// T5 role editor: name, a color from 8 swatches, and the six permissions.
struct RoleEditor: View {
    let model: TeamsModel
    let isTop: Bool
    @State private var role: TeamRole
    @State private var isNew: Bool
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: TeamsModel, role: TeamRole, isTop: Bool) {
        self.model = model
        self.isTop = isTop
        _role = State(initialValue: role)
        _isNew = State(initialValue: role.name.isEmpty)
    }

    private var swatches: [ColorToken] {
        [Palette.chalk, Palette.dust, Palette.gravel, Palette.seam, Palette.sodium, Palette.brake, Palette.go, Palette.xenon]
    }

    private var permissionRows: [(TeamPermissions, LocalizedStringKey, LocalizedStringKey)] {
        [(.manageTeam, "Manage team", "Edit the team's icon, name, and about."),
         (.manageChannels, "Manage channels", "Add, rename, reorder, and delete channels."),
         (.manageRoles, "Manage roles", "Edit roles and change members' roles."),
         (.kick, "Remove members", "Remove members from the team."),
         (.deleteMessages, "Delete messages", "Delete anyone's messages in the team."),
         (.hostMeets, "Host meets", "Start meets for the team.")]
    }

    var body: some View {
        Sheet(Text(isNew ? "New role" : "Edit role")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Field("Name", text: $role.name, limit: 30)
                    SectionLabel("COLOR")
                    HStack(spacing: Space.s12) {
                        ForEach(swatches) { s in
                            Button { role.colorHex = s.hex } label: {
                                Circle().fill(s.color).frame(width: Space.s32, height: Space.s32)
                                    .overlay(Circle().strokeBorder(role.colorHex == s.hex ? Color.sodium : .clear, lineWidth: Size.Marker.ring))
                                    .frame(width: Size.hitTarget, height: Size.hitTarget)
                            }
                            .buttonStyle(PressScaleStyle())
                            .accessibilityLabel(Text(verbatim: s.name))
                            .accessibilityAddTraits(role.colorHex == s.hex ? .isSelected : [])
                        }
                    }
                    SectionLabel("PERMISSIONS")
                    VStack(spacing: 0) {
                        ForEach(Array(permissionRows.enumerated()), id: \.offset) { _, p in
                            Row(Text(p.1), subtitle: Text(p.2), trailing: {
                                Toggle("", isOn: Binding(get: { role.permissions.contains(p.0) },
                                                         set: { on in if on { role.permissions.insert(p.0) } else { role.permissions.remove(p.0) } }))
                                    .labelsHidden().tint(.sodium)
                            })
                        }
                    }
                    .disabled(isTop)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Save role", isLoading: working) {
                        run {
                            // SAFE-4: same client-side word check as posts, listings, and messages.
                            if case .blocked = await model.env.safety.check(role.name) {
                                self.error = String(localized: "That role can't be saved.", bundle: .module)
                                return
                            }
                            var r = role
                            r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            _ = try await model.env.teams.saveRole(r)
                        }
                    }
                    .disabled(role.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !isNew && !isTop {
                        DestructiveButton("Delete role", confirmTitle: "Delete role", consequence: "Members with this role keep their place in the team without it.") {
                            let id = role.id
                            run { try await model.env.teams.deleteRole(id) }
                        }
                    }
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
    }

    private func run(_ body: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await body()
                dismiss()
            } catch WaypointsError.rateLimited {
                self.error = String(localized: "You're doing that a lot. Try again in a few minutes.", bundle: .module)
            } catch {
                self.error = String(localized: "Couldn't save. Check your connection and try again.", bundle: .module)
            }
            working = false
        }
    }
}

/// T5 "Meets": the team's meets that have not ended.
struct TeamMeets: View {
    let model: TeamsModel
    let teamID: TeamID
    @State private var meets: [Meet]?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let meets {
                    if meets.isEmpty {
                        Text("No meets planned for this team.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust).padding(Space.margin)
                    }
                    ForEach(meets) { m in
                        Button { model.env.router.open(.meet(m.id)) } label: {
                            Row(Text(verbatim: m.title), subtitle: m.placeName.isEmpty ? nil : Text(verbatim: m.placeName), trailing: {
                                Text(readout: m.startsAt.formatted(date: .abbreviated, time: .shortened), token: .readoutS)
                            })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                } else {
                    SkeletonRow(); SkeletonRow(); SkeletonRow()
                }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(Text("Meets", bundle: .module))
        .task {
            var list = (try? await model.env.teams.meets(of: teamID)) ?? []
            if list.isEmpty, let me = model.me {
                list = ((try? await model.env.meets.upcomingMeets(for: me)) ?? []).filter { $0.teamID == teamID }
            }
            meets = list
        }
    }
}

/// T6: members grouped by role in rank order. With permission, swipe for "Change role" and "Remove".
struct MembersView: View {
    let model: TeamsModel
    let teamID: TeamID
    let ownerID: UserID
    let perms: TeamPermissions
    let roles: [TeamRole]
    @State private var members: [TeamMember] = []
    @State private var profiles: [UserID: Profile] = [:]
    @State private var changing: MemberRef?
    @State private var removing: MemberRef?
    @State private var error: String?

    struct MemberRef: Identifiable {
        let member: TeamMember
        var id: UserID { member.userID }
    }

    var body: some View {
        List {
            if let error {
                Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake).padding(.horizontal, Space.margin).plainRow()
            }
            ForEach(roles) { role in
                let inRole = members.filter { $0.roleID == role.id }
                if !inRole.isEmpty {
                    SectionLabel(verbatim: role.name.uppercased()).plainRow()
                    ForEach(inRole, id: \.userID) { m in row(m) }
                }
            }
            let unassigned = members.filter { m in !roles.contains { $0.id == m.roleID } }
            if !unassigned.isEmpty {
                SectionLabel("MEMBERS").plainRow()
                ForEach(unassigned, id: \.userID) { m in row(m) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(Text("Members", bundle: .module))
        .sheet(item: $changing) { ref in rolePicker(ref.member) }
        .confirmationDialog("Remove \(removing.flatMap { profiles[$0.id]?.displayName } ?? "member")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let ref = removing {
                    act { try await model.env.teams.kick(ref.id, from: teamID) }
                }
                removing = nil
            }
        } message: {
            Text("They'll need an invite to come back to a private team.", bundle: .module)
        }
        .task { await load() }
    }

    private func row(_ m: TeamMember) -> some View {
        let p = profiles[m.userID]
        let actionable = m.userID != model.me && m.userID != ownerID
        return Button { model.env.router.open(.profile(m.userID)) } label: {
            Row(Text(verbatim: p?.displayName ?? ""), subtitle: p.map { Text(verbatim: "@\($0.handle)") }, leading: {
                Avatar(name: p?.displayName ?? "", url: p?.avatarPath.map { model.env.media.publicURL(bucket: .avatars, path: $0) }, size: .s40)
            })
        }
        .buttonStyle(RowButtonStyle())
        .plainRow()
        .contextMenu {
            if m.userID != model.me {
                Button("Report") { model.env.router.open(.reportContent(.user(m.userID))) }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actionable && perms.contains(.kick) {
                Button("Remove", role: .destructive) { removing = MemberRef(member: m) }
            }
            if actionable && perms.contains(.manageRoles) {
                Button("Change role") { changing = MemberRef(member: m) }.tint(Color.curb)
            }
        }
    }

    private func rolePicker(_ m: TeamMember) -> some View {
        Sheet(Text("Change role", bundle: .module)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(roles) { r in
                        Button {
                            changing = nil
                            act { try await model.env.teams.assign(r.id, to: m.userID, in: teamID) }
                        } label: {
                            Row(Text(verbatim: r.name), leading: {
                                Circle().fill(r.colorHex.flatMap { Color(paintHex: $0) } ?? .dust).frame(width: Space.s12, height: Space.s12)
                            }, trailing: {
                                if m.roleID == r.id { Image.symbol(Symbol.confirm).foregroundStyle(Color.sodium).accessibilityHidden(true) }
                            })
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityAddTraits(m.roleID == r.id ? .isSelected : [])
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func act(_ body: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await body() } catch {
                self.error = String(localized: "Couldn't do that. Check your connection and try again.", bundle: .module)
            }
            await load()
        }
    }

    private func load() async {
        members = (try? await model.env.teams.members(of: teamID)) ?? []
        for p in (try? await model.env.profiles.profiles(members.map(\.userID))) ?? [] { profiles[p.userID] = p }
    }
}

private extension View {
    /// A `List` row that looks like the rest of the app: no insets, no separator, `asphalt` behind.
    func plainRow() -> some View {
        listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.asphalt)
    }
}
