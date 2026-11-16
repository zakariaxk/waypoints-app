import Core
import DesignSystem
import MapKit
import SwiftUI

/// Convoys (plan 10.3 M9): start, join by code, live members with gaps as time, regroup.
/// `joinConvoy(code: "")` opens the start-or-join sheet.
public enum ConvoyFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let store = ConvoyStore(env: env)
        registry.registerMapAction(StartConvoyAction())
        registry.registerMapSheetSection(ConvoySection(store: store))
        registry.registerMapLayer(ConvoyLayer(store: store))
        registry.registerRoute(.joinConvoy, presentation: .sheet) { route in
            guard case let .joinConvoy(code) = route else { return nil }
            return AnyView(ConvoySheet(store: store, code: code))
        }
        #if DEBUG
        registry.registerDebugScreen("convoy-regroup") { AnyView(RegroupSheet(store: store)) }
        // `waypoints://debug/convoy-live`: joins the preview convoy so the map behind this
        // half-sheet draws the shared route line and the leader tick (CNV-5).
        registry.registerDebugScreen("convoy-live") {
            AnyView(ScrollView { ConvoySectionView(store: store) }
                .background(Color.tarmac)
                .presentationDetents([.medium])
                .task { if store.state == nil { try? await store.join(code: "R70RUN") } })
        }
        #endif
        store.start()
    }
}

struct Member: Identifiable, Hashable {
    var id: RealtimeUID { uid }
    var uid: RealtimeUID
    var name: String
    var coordinate: Coordinate?
    var fixAt: Date?
}

@MainActor
@Observable
final class ConvoyStore {
    let env: AppEnvironment
    var state: ConvoyState? {
        didSet {
            guard (state != nil) != (oldValue != nil) else { return }
            let active = state != nil
            if active { lastRolled = nil }
            Task { await env.location.setActive(.convoy, active) }
        }
    }
    var name = ""
    var code: String?
    var myUID: RealtimeUID?
    var me: Coordinate?
    var positions: [RealtimeUID: (Coordinate, Date, String)] = [:]
    var splitSince: Date?
    var regroupPlace: String?
    /// Set when the leader ended the convoy for everyone else; "Convoy ended." (CNV-7).
    var ended = false
    /// CNV-15: the convoy this driver just ended, kept for the toast's lifetime so "Roll again"
    /// can start a new one with the same drivers.
    var lastRolled: (name: String, destination: ConvoyDestination?, memberUIDs: [RealtimeUID])?
    var error: String?
    @ObservationIgnored private var ending = false
    @ObservationIgnored private var started = false

    init(env: AppEnvironment) { self.env = env }

    var isLeader: Bool { state != nil && state?.leaderUID == myUID }

    func start() {
        guard !started else { return }
        started = true
        let env = self.env
        Task { [weak self] in
            self?.myUID = try? await env.profiles.myProfile().uid
        }
        Task { [weak self] in
            for await event in await env.realtime.events() {
                guard let self else { return }
                switch event {
                case let .convoy(s):
                    if s.ended {
                        guard s.id == self.state?.id else { break }
                        self.state = nil
                        self.clear()
                        if !self.ending { self.ended = true }
                    } else {
                        if let r = s.regroup, r != self.state?.regroup { self.resolveRegroup(r.coordinate) }
                        self.state = s
                        self.ended = false
                    }
                case let .entities(updates):
                    for u in updates where u.info?.relation == .convoy || self.state?.memberUIDs.contains(u.uid) == true {
                        let n = u.info?.displayName ?? self.positions[u.uid]?.2 ?? ""
                        self.positions[u.uid] = (u.coordinate, .now, n)
                    }
                    self.checkSplit()
                default: break
                }
            }
        }
        Task { [weak self] in
            for await s in await env.location.samples() { self?.me = s.coordinate }
        }
        // Core's active convoy: picks up a convoy joined elsewhere, e.g. a cruise's Roll out (MEET-13).
        Task { [weak self] in
            for await active in await env.realtime.activeConvoy() {
                guard let self else { return }
                guard let active, active.id != self.state?.id else { continue }
                self.state = active.memberUIDs.isEmpty
                    ? ConvoyState(id: active.id, leaderUID: self.myUID ?? 0, memberUIDs: self.myUID.map { [$0] } ?? [],
                                  destination: active.destination, routePolyline: active.routePolyline)
                    : active
                self.ended = false
            }
        }
    }

    /// Takes on a convoy this device already joined, with the code it was shared under.
    func adopt(code: String) async {
        guard let active = await env.realtime.currentConvoy() else { return }
        if state?.id != active.id {
            state = active.memberUIDs.isEmpty
                ? ConvoyState(id: active.id, leaderUID: myUID ?? 0, memberUIDs: myUID.map { [$0] } ?? [])
                : active
        }
        self.code = code.uppercased()
    }

    var members: [Member] {
        guard let s = state else { return [] }
        return s.memberUIDs.map { uid in
            let p = positions[uid]
            return Member(uid: uid, name: uid == myUID ? String(localized: "You", bundle: .module)
                              : (p?.2.isEmpty == false ? p!.2 : String(localized: "Driver", bundle: .module)),
                          coordinate: uid == myUID ? me : p?.0, fixAt: uid == myUID ? .now : p?.1)
        }
    }

    var leaderPosition: Coordinate? { members.first { $0.uid == state?.leaderUID }?.coordinate }

    /// Gap to the leader as time at a cruising 20 m/s; never a speed.
    func gap(_ m: Member) -> TimeInterval? {
        guard let l = leaderPosition, let c = m.coordinate, m.uid != state?.leaderUID else { return nil }
        return l.distance(to: c) / 20
    }

    private func checkSplit() {
        guard isLeader else { return }
        let worst = members.compactMap(gap).max() ?? 0
        if worst > 180 { splitSince = splitSince ?? .now } else { splitSince = nil }
    }

    var shouldOfferRegroup: Bool {
        isLeader && state?.regroup == nil && (splitSince.map { Date.now.timeIntervalSince($0) > 60 } ?? false)
    }

    func create(name: String, destination: ConvoyDestination?) async throws {
        if myUID == nil { myUID = try? await env.profiles.myProfile().uid }
        let invite = try await env.gateway.createConvoy(name: name, destination: destination)
        code = invite.joinCode
        self.name = name
        state = ConvoyState(id: invite.id, leaderUID: myUID ?? 0, memberUIDs: myUID.map { [$0] } ?? [], destination: destination)
        await env.realtime.joinConvoy(invite.id)
    }

    func join(code: String) async throws {
        if myUID == nil { myUID = try? await env.profiles.myProfile().uid }
        let s = try await env.gateway.joinConvoy(code: code.uppercased())
        state = s
        self.code = code.uppercased()
        await env.realtime.joinConvoy(s.id)
    }

    func leave() async {
        await env.realtime.leaveConvoy()
        state = nil
        clear()
    }

    private func clear() {
        code = nil
        name = ""
        positions = [:]
        splitSince = nil
        regroupPlace = nil
        error = nil
    }

    func end() async {
        guard let s = state else { return }
        ending = true
        error = nil
        let rolled = (name: name, destination: s.destination, memberUIDs: s.memberUIDs)
        do {
            try await env.gateway.endConvoy(s.id)
            await leave()
            lastRolled = rolled
        } catch WaypointsError.notFound {
            await leave()
            lastRolled = rolled
        } catch {
            self.error = String(localized: "Couldn't end the convoy. Check your connection and try again.", bundle: .module)
        }
        ending = false
    }

    /// CNV-15: the leader's one tap back on the road — a new convoy to the same destination
    /// with the same drivers invited; each still has to accept.
    func rollAgain() async {
        guard let rolled = lastRolled else { return }
        lastRolled = nil
        error = nil
        var users: [UserID] = []
        for uid in rolled.memberUIDs where uid != myUID {
            if let user = try? await env.profiles.profile(uid: uid)?.userID { users.append(user) }
        }
        do {
            var name = rolled.name
            if name.isEmpty, let p = try? await env.profiles.myProfile() { name = "\(p.displayName)'s convoy" }
            try await create(name: name, destination: rolled.destination)
            if let id = state?.id, !users.isEmpty { try? await env.gateway.inviteToConvoy(id, users: users) }
            if let code { env.router.open(.joinConvoy(code: code)) }
        } catch {
            self.error = String(localized: "Couldn't start the convoy. Check your connection and try again.", bundle: .module)
        }
    }

    /// The leader changes the shared destination (CNV-7); the gateway's ConvoyState carries it to members.
    func setDestination(_ d: ConvoyDestination) async throws {
        guard let id = state?.id else { return }
        try await env.gateway.setConvoyDestination(id, d)
        state?.destination = d
    }

    /// SAFE-1: every member is reportable. Member uids are realtime uids, resolved
    /// through the profile the way VoiceFeature resolves its participants.
    func report(_ m: Member) async {
        guard m.uid != myUID, let user = (try? await env.profiles.profile(uid: m.uid))?.userID else { return }
        env.router.open(.reportContent(.user(user)))
    }

    /// Every convoy has its own voice room (CNV-11); VoiceFeature joins it muted.
    func talk() {
        guard let id = state?.id else { return }
        env.router.open(.convoyVoice(id))
    }

    /// Drops a pull-off pin: the nearest fuel or parking point within 3 km ahead, else the leader.
    func regroup() async {
        guard let id = state?.id, let here = me else { return }
        let request = MKLocalPointsOfInterestRequest(center: here.cl, radius: 3000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .parking])
        let found: Coordinate? = await withCheckedContinuation { c in
            MKLocalSearch(request: request).start { response, _ in
                let item = response?.mapItems.first?.placemark.coordinate
                c.resume(returning: item.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) })
            }
        }
        do {
            try await env.gateway.setConvoyRegroup(id, at: found ?? here)
            splitSince = nil
            error = nil
        } catch {
            self.error = String(localized: "Couldn't set the regroup point. Check your connection and try again.", bundle: .module)
        }
    }

    /// Any member drops the regroup point (CNV-12). Shown at once; the gateway's ConvoyState follows.
    func dropRegroup(at c: Coordinate) async throws {
        guard let id = state?.id else { return }
        try await env.gateway.setConvoyRegroup(id, at: c)
        state?.regroup = ConvoyRegroup(coordinate: c, setAt: .now)
        resolveRegroup(c)
    }

    /// The leader's "Rolling": clears the regroup point for everyone (CNV-12).
    func rolling() async {
        guard let id = state?.id else { return }
        do {
            try await env.gateway.clearConvoyRegroup(id)
            state?.regroup = nil
            error = nil
        } catch {
            self.error = String(localized: "Couldn't clear the regroup point. Check your connection and try again.", bundle: .module)
        }
    }

    private func resolveRegroup(_ c: Coordinate) {
        regroupPlace = nil
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { marks, _ in
            let name = marks?.first?.name
            MainActor.assumeIsolated { self.regroupPlace = name ?? "the pin" }
        }
    }
}

struct StartConvoyAction: MapAction {
    var id: String { "convoy" }
    var title: String { String(localized: "Start a convoy", bundle: .module) }
    var symbol: String { "car.rear.and.tire.marks" }
    var order: Int { 30 }
    @MainActor func perform(at coordinate: Coordinate, router: any Router) { router.open(.joinConvoy(code: "")) }
}

struct ConvoyLayer: MapLayerProvider {
    let store: ConvoyStore
    var id: String { "convoy" }
    func items(in region: MapRegion) -> AsyncStream<[MapItem]> {
        AsyncStream { c in
            let task = Task { @MainActor in
                var last = ""
                while !Task.isCancelled {
                    var items: [MapItem] = []
                    if let s = store.state {
                        if let d = s.destination {
                            items.append(MapItem(id: "dest", coordinate: d.coordinate, glyph: "pin", tint: .sodium, title: d.name, priority: 9))
                        }
                        if let r = s.regroup {
                            items.append(MapItem(id: "regroup", coordinate: r.coordinate, glyph: "pin", tint: .go, title: "Regroup", priority: 10))
                        }
                        // CNV-5: the sodium tick on the leader's marker.
                        if let leader = store.leaderPosition {
                            items.append(MapItem(id: "leader", coordinate: leader, glyph: "leader", tint: .sodium,
                                                 title: String(localized: "Leader", bundle: .module), priority: 8))
                        }
                    }
                    let signature = items.map { "\($0.id)\($0.title ?? "")\($0.coordinate.latitude)\($0.coordinate.longitude)" }.joined()
                    if signature != last { c.yield(items); last = signature }
                    try? await Task.sleep(for: .seconds(1))
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    /// CNV-5: the shared route as a line under the markers.
    func paths(in region: MapRegion) -> AsyncStream<[MapPath]> {
        AsyncStream { c in
            let task = Task { @MainActor in
                var last = Data()
                while !Task.isCancelled {
                    let data = store.state?.routePolyline ?? Data()
                    if data != last {
                        last = data
                        let coordinates = decodePolyline(data)
                        c.yield(coordinates.count > 1 ? [MapPath(id: "route", coordinates: coordinates, tint: .sodium)] : [])
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    @MainActor func detail(for item: MapItem) -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: Space.s12) {
            Text(verbatim: item.title ?? "").typeStyle(.title).foregroundStyle(Color.chalk)
            PrimaryButton("Directions") { store.env.router.open(.navigate(to: item.coordinate, name: item.title)) }
        }.padding(.horizontal, Space.margin))
    }
}

/// Google encoded polyline, precision 5 — the shape a shared convoy route arrives as (MEET-13).
func decodePolyline(_ data: Data) -> [Coordinate] {
    let bytes = [UInt8](data)
    var out: [Coordinate] = []
    var lat = 0, lng = 0, i = 0
    func chunk() -> Int? {
        var shift = 0, result = 0
        while i < bytes.count {
            let b = Int(bytes[i]) - 63
            i += 1
            result |= (b & 0x1f) << shift
            shift += 5
            if b < 0x20 { return result }
        }
        return nil
    }
    while i < bytes.count {
        guard let dLat = chunk(), let dLng = chunk() else { break }
        lat += (dLat & 1) != 0 ? ~(dLat >> 1) : (dLat >> 1)
        lng += (dLng & 1) != 0 ? ~(dLng >> 1) : (dLng >> 1)
        out.append(Coordinate(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
    }
    return out
}

struct ConvoySection: MapSheetSection {
    let store: ConvoyStore
    var id: String { "convoy" }
    var order: Int { 0 }
    @MainActor func view(region: MapRegion) -> AnyView { AnyView(ConvoySectionView(store: store)) }
}

struct ConvoySectionView: View {
    let store: ConvoyStore
    @State private var confirmEnd = false
    @State private var dropping = false
    @State private var changingDestination = false

    var body: some View {
        if let s = store.state {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(verbatim: store.name.isEmpty ? String(localized: "Convoy", bundle: .module) : store.name).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                        Text("\(s.memberUIDs.count) drivers", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    Spacer()
                    QuietButton("Talk") { store.talk() }
                    if store.isLeader {
                        QuietButton("End convoy") { confirmEnd = true }
                    } else {
                        QuietButton("Leave") { Task { await store.leave() } }
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s8)
                .background(Color.sodiumDim)
                if let error = store.error {
                    Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake)
                        .padding(.horizontal, Space.margin).padding(.vertical, Space.s8)
                }
                if store.shouldOfferRegroup {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text("The group has split. Set a regroup point?", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
                        SecondaryButton("Set regroup point") { Task { await store.regroup() } }
                    }
                    .padding(Space.margin)
                }
                if let r = s.regroup {
                    HStack {
                        Text("Regroup at \(store.regroupPlace ?? "the pin")", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.go)
                        Spacer()
                        QuietButton("Directions") { store.env.router.open(.navigate(to: r.coordinate, name: store.regroupPlace)) }
                        if store.isLeader {
                            QuietButton("Rolling") { Task { await store.rolling() } }
                        }
                    }
                    .padding(.horizontal, Space.margin).padding(.vertical, Space.s8)
                } else {
                    QuietButton("Drop a regroup point") { dropping = true }
                        .padding(.horizontal, Space.margin)
                }
                if let d = s.destination {
                    HStack {
                        Text("Heading to \(d.name)", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
                        Spacer()
                        if store.isLeader {
                            QuietButton("Change") { changingDestination = true }
                        }
                    }
                    .padding(.horizontal, Space.margin).padding(.vertical, Space.s8)
                } else if store.isLeader {
                    QuietButton("Set a destination") { changingDestination = true }
                        .padding(.horizontal, Space.margin)
                }
                SectionLabel("CONVOY")
                ForEach(store.members.sorted { (store.gap($0) ?? 0) < (store.gap($1) ?? 0) }) { m in
                    Row(Text(verbatim: m.name), leading: {
                        // Every row keeps the slot so names line up; only the leader's shows.
                        Image(systemName: "flag.fill").foregroundStyle(Color.sodium)
                            .opacity(m.uid == s.leaderUID ? 1 : 0)
                            .accessibilityLabel(Text("Leader", bundle: .module))
                            .accessibilityHidden(m.uid != s.leaderUID)
                    }, trailing: {
                        if let fix = m.fixAt, Date.now.timeIntervalSince(fix) > 60 {
                            Text("Lost signal", bundle: .module).typeStyle(.foot)
                        } else if let g = store.gap(m) {
                            Text(readout: "+\(Int(g).formatted(.number)) s", token: .readoutS)
                                .accessibilityLabel(Text("\(Int(g).formatted(.number)) seconds behind", bundle: .module))
                        }
                    })
                    .contextMenu {
                        if m.uid != store.myUID {
                            Button("Report") { Task { await store.report(m) } }
                        }
                    }
                }
            }
            .confirmationDialog("End the convoy for all \(s.memberUIDs.count) drivers?", isPresented: $confirmEnd) {
                Button("End convoy", role: .destructive) { Task { await store.end() } }
            }
            .sheet(isPresented: $dropping) { RegroupSheet(store: store) }
            .sheet(isPresented: $changingDestination) { DestinationSheet(store: store) }
        } else if store.ended || store.lastRolled != nil {
            HStack {
                Text("Convoy ended.", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                Spacer()
                // CNV-15: only the driver who ended it gets the one-tap redo.
                if store.lastRolled != nil {
                    QuietButton("Roll again") { Task { await store.rollAgain() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.margin)
            .padding(.vertical, Space.s8)
            .background(Color.sodiumDim)
            .task {
                try? await Task.sleep(for: .seconds(Timing.toast))
                store.ended = false
                store.lastRolled = nil
            }
        }
    }
}

struct ConvoySheet: View {
    @Bindable var store: ConvoyStore
    @State var code: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var place = ""
    @State private var friends: [Friend] = []
    @State private var invited: Set<UserID> = []
    @State private var destination: ConvoyDestination?
    @State private var loops: [RoadLoop] = []
    @State private var pickedLoop: LoopID?
    @State private var joining = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Sheet(store.state != nil ? Text("Convoy", bundle: .module)
              : code.isEmpty && !joining ? Text("Start a convoy", bundle: .module) : Text("Join convoy", bundle: .module)) {
            VStack(alignment: .leading, spacing: Space.s16) {
                if store.state != nil, let c = store.code {
                    Text(verbatim: c).typeStyle(.readoutL).foregroundStyle(Color.chalk)
                    if let url = Route.joinConvoy(code: c).shareURL {
                        QRCodeView(url.absoluteString)
                            .frame(maxWidth: Size.row * 6)
                        ShareLink(item: url) {
                            Text("Share invite", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.sodium)
                                .frame(minHeight: Size.hitTarget).contentShape(Rectangle())
                        }
                    }
                    if !friends.isEmpty {
                        SectionLabel("INVITE FRIENDS").padding(.horizontal, -Space.margin)
                        ScrollView {
                            ForEach(friends) { f in
                                Button {
                                    if invited.contains(f.id) { invited.remove(f.id) } else { invited.insert(f.id) }
                                } label: {
                                    Row(Text(verbatim: f.profile.displayName), leading: { Avatar(name: f.profile.displayName, size: .s28) },
                                        trailing: {
                                            Image(systemName: invited.contains(f.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(invited.contains(f.id) ? Color.sodium : Color.gravel)
                                                .accessibilityHidden(true)
                                        })
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityAddTraits(invited.contains(f.id) ? .isSelected : [])
                            }
                        }
                        .frame(maxHeight: Size.row * 3)
                        .padding(.horizontal, -Space.margin)
                    }
                    PrimaryButton(invited.isEmpty ? "Done" : "Invite friends", isLoading: working) {
                        guard let id = store.state?.id, !invited.isEmpty else { dismiss(); return }
                        let users = Array(invited)
                        run { try await store.env.gateway.inviteToConvoy(id, users: users); dismiss() }
                    }
                } else if !code.isEmpty || joining {
                    Field("Code", text: $code, prompt: "6 characters").textInputAutocapitalization(.characters)
                    Text("Everyone in the convoy sees your exact location until you leave.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                    PrimaryButton("Join convoy", isLoading: working) {
                        run { try await store.join(code: code); dismiss() }
                    }
                    .disabled(code.count != 6)
                } else {
                    Field("Name", text: $name, limit: 40)
                    Field("Destination", text: $place, prompt: "Optional: where you're headed")
                        .onSubmit { Task { await findDestination() } }
                        // Editing the text after a geocode must drop the resolved point,
                        // or the convoy silently keeps the old destination.
                        .onChange(of: place) { destination = nil; pickedLoop = nil }
                    if let destination {
                        Text("Heading to \(destination.name)", bundle: .module).typeStyle(.sub).foregroundStyle(Color.go)
                    }
                    if !loops.isEmpty {
                        // CNV-14: aim the convoy at a saved loop instead of a searched place.
                        Text("From a saved loop", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Space.s8) {
                                ForEach(loops) { loop in
                                    Chip(LocalizedStringKey(loop.name), isSelected: pickedLoop == loop.id) { pick(loop) }
                                }
                            }
                        }
                        .contentMargins(.horizontal, Space.margin, for: .scrollContent)
                        .padding(.horizontal, -Space.margin)
                    }
                    Text("Everyone in the convoy sees your exact location until you leave.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                    PrimaryButton("Start convoy", isLoading: working) {
                        run {
                            // No destination yet: resolve the typed place (a loop pick already set it).
                            if destination == nil { await findDestination() }
                            try await store.create(name: name, destination: destination)
                        }
                    }
                    QuietButton("Join with code") { joining = true }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium])
        .task {
            // Roll out (MEET-13) joins before opening this sheet with the code: show the invite, not the join form.
            if store.code == nil, !code.isEmpty { await store.adopt(code: code) }
            if name.isEmpty, let p = try? await store.env.profiles.myProfile() { name = "\(p.displayName)'s convoy" }
            friends = (try? await store.env.friends.friends()) ?? []
            loops = (try? await store.env.roads.myLoops()) ?? []
        }
    }

    /// Resolves the typed place into the convoy's destination (first local search hit).
    private func findDestination() async {
        guard !place.isEmpty else { destination = nil; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        let found: ConvoyDestination? = await withCheckedContinuation { done in
            MKLocalSearch(request: request).start { response, _ in
                let item = response?.mapItems.first
                let c = item?.placemark.coordinate
                let name = item?.name ?? ""
                done.resume(returning: c.map { ConvoyDestination(coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude), name: name) })
            }
        }
        if let found { destination = found }
    }

    /// CNV-14: a loop chip sets the destination to the loop's end, named for the loop;
    /// tapping the picked chip drops it, the way editing the place text does.
    private func pick(_ loop: RoadLoop) {
        if pickedLoop == loop.id {
            pickedLoop = nil
            destination = nil
            return
        }
        place = ""
        Task { await aim(at: loop) }
    }

    /// The loop's end: its roads joined in order, reversing a road when its far end meets the
    /// road before it — the same walking LoopDetail's joined path does, kept to the last point.
    private func aim(at loop: RoadLoop) async {
        var end: Coordinate?
        for id in loop.roadIDs {
            guard let road = try? await store.env.roads.road(id),
                  let first = road.path.first, let last = road.path.last else { continue }
            end = end.map { $0.distance(to: last) < $0.distance(to: first) ? first : last } ?? last
        }
        // The place field won while roads loaded: leave its cleared destination alone.
        guard let end, place.isEmpty, pickedLoop == nil else { return }
        pickedLoop = loop.id
        destination = ConvoyDestination(coordinate: end, name: loop.name)
    }

    private func run(_ body: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await body() } catch WaypointsError.notFound {
                error = String(localized: "No convoy with that code.", bundle: .module)
            } catch {
                self.error = String(localized: "Couldn't reach the convoy. Check your connection and try again.", bundle: .module)
            }
            working = false
        }
    }
}

/// Drop a regroup point by place search or "here" (CNV-12).
struct RegroupSheet: View {
    let store: ConvoyStore
    @Environment(\.dismiss) private var dismiss
    @State private var place = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Sheet(Text("Regroup", bundle: .module)) {
            VStack(alignment: .leading, spacing: Space.s16) {
                Field("Place", text: $place, prompt: "Search for a place")
                    .onSubmit { drop(searching: true) }
                PrimaryButton("Regroup there", isLoading: working) { drop(searching: true) }
                    .disabled(place.isEmpty)
                SecondaryButton("Regroup here") { drop(searching: false) }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium])
    }

    private func drop(searching: Bool) {
        guard !working, !searching || !place.isEmpty else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            let found: Coordinate? = if searching { await find() } else { store.me }
            guard let point = found else {
                error = searching ? String(localized: "No place found. Try another search.", bundle: .module)
                    : String(localized: "Couldn't find your location. Search for a place instead.", bundle: .module)
                return
            }
            do {
                try await store.dropRegroup(at: point)
                dismiss()
            } catch {
                self.error = String(localized: "Couldn't set the regroup point. Check your connection and try again.", bundle: .module)
            }
        }
    }

    /// First local search hit for the typed place, near the driver.
    private func find() async -> Coordinate? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        if let me = store.me { request.region = MKCoordinateRegion(center: me.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        return await withCheckedContinuation { done in
            MKLocalSearch(request: request).start { response, _ in
                let c = response?.mapItems.first?.placemark.coordinate
                done.resume(returning: c.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) })
            }
        }
    }
}

/// The leader picks a new shared destination by place search (CNV-7); same search flow as starting a convoy.
struct DestinationSheet: View {
    let store: ConvoyStore
    @Environment(\.dismiss) private var dismiss
    @State private var place = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Sheet(Text("Destination", bundle: .module)) {
            VStack(alignment: .leading, spacing: Space.s16) {
                Field("Place", text: $place, prompt: "Search for a place")
                    .onSubmit { set() }
                PrimaryButton("Set destination", isLoading: working) { set() }
                    .disabled(place.isEmpty)
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium])
    }

    private func set() {
        guard !working, !place.isEmpty else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            guard let found = await find() else {
                error = String(localized: "No place found. Try another search.", bundle: .module)
                return
            }
            do {
                try await store.setDestination(found)
                dismiss()
            } catch {
                self.error = String(localized: "Couldn't change the destination. Check your connection and try again.", bundle: .module)
            }
        }
    }

    /// First local search hit for the typed place, near the driver.
    private func find() async -> ConvoyDestination? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        if let me = store.me { request.region = MKCoordinateRegion(center: me.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        return await withCheckedContinuation { done in
            MKLocalSearch(request: request).start { response, _ in
                let item = response?.mapItems.first
                let c = item?.placemark.coordinate
                done.resume(returning: c.map { ConvoyDestination(coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude), name: item?.name ?? "") })
            }
        }
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
