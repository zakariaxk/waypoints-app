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
    var state: ConvoyState?
    var name = ""
    var code: String?
    var myUID: RealtimeUID?
    var me: Coordinate?
    var positions: [RealtimeUID: (Coordinate, Date, String)] = [:]
    var splitSince: Date?
    var regroupPlace: String?
    /// Set when the leader ended the convoy for everyone else; "Convoy ended." (CNV-7).
    var ended = false
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
                        if !self.ending { self.ended = true }
                    } else {
                        if s.regroup != nil && s.regroup != self.state?.regroup { self.resolveRegroup(s.regroup!.coordinate) }
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
            return Member(uid: uid, name: uid == myUID ? "You" : (p?.2.isEmpty == false ? p!.2 : "Driver"),
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
        let invite = try await env.gateway.createConvoy(name: name, destination: destination)
        code = invite.joinCode
        self.name = name
        state = ConvoyState(id: invite.id, leaderUID: myUID ?? 0, memberUIDs: myUID.map { [$0] } ?? [], destination: destination)
        await env.realtime.joinConvoy(invite.id)
    }

    func join(code: String) async throws {
        let s = try await env.gateway.joinConvoy(code: code)
        state = s
        self.code = code.uppercased()
        await env.realtime.joinConvoy(s.id)
    }

    func leave() async {
        await env.realtime.leaveConvoy()
        state = nil
    }

    func end() async {
        guard let id = state?.id else { return }
        ending = true
        try? await env.gateway.endConvoy(id)
        await leave()
        ending = false
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
        try? await env.gateway.setConvoyRegroup(id, at: found ?? here)
        splitSince = nil
    }

    private func resolveRegroup(_ c: Coordinate) {
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
            Task { @MainActor in
                var items: [MapItem] = []
                if let d = store.state?.destination {
                    items.append(MapItem(id: "dest", coordinate: d.coordinate, glyph: "pin", tint: .sodium, title: d.name, priority: 9))
                }
                if let r = store.state?.regroup {
                    items.append(MapItem(id: "regroup", coordinate: r.coordinate, glyph: "pin", tint: .go, title: "Regroup", priority: 10))
                }
                c.yield(items)
                c.finish()
            }
        }
    }
    @MainActor func detail(for item: MapItem) -> AnyView? {
        AnyView(VStack(alignment: .leading, spacing: Space.s12) {
            Text(verbatim: item.title ?? "").typeStyle(.title).foregroundStyle(Color.chalk)
            PrimaryButton("Directions") { store.env.router.open(.navigate(to: item.coordinate, name: item.title)) }
        }.padding(.horizontal, Space.margin))
    }
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

    var body: some View {
        if let s = store.state {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: store.name.isEmpty ? "Convoy" : store.name).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
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
                if store.shouldOfferRegroup {
                    VStack(alignment: .leading, spacing: Space.s8) {
                        Text("The group has split. Set a regroup point?", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
                        SecondaryButton("Set regroup point") { Task { await store.regroup() } }
                    }
                    .padding(Space.margin)
                }
                if let r = s.regroup {
                    HStack {
                        Text("Regroup at \(store.regroupPlace ?? "the pin")").typeStyle(.bodyStrong).foregroundStyle(Color.go)
                        Spacer()
                        QuietButton("Directions") { store.env.router.open(.navigate(to: r.coordinate, name: store.regroupPlace)) }
                    }
                    .padding(.horizontal, Space.margin).padding(.vertical, Space.s8)
                }
                SectionLabel("CONVOY")
                ForEach(store.members.sorted { (store.gap($0) ?? 0) < (store.gap($1) ?? 0) }) { m in
                    Row(Text(verbatim: m.name), leading: {
                        if m.uid == s.leaderUID {
                            Image(systemName: "flag.fill").foregroundStyle(Color.sodium).accessibilityLabel(Text("Leader", bundle: .module))
                        }
                    }, trailing: {
                        if let fix = m.fixAt, Date.now.timeIntervalSince(fix) > 60 {
                            Text("Lost signal", bundle: .module).typeStyle(.foot)
                        } else if let g = store.gap(m) {
                            Text(verbatim: "+\(Int(g)) s").typeStyle(.readoutS)
                        }
                    })
                }
            }
            .confirmationDialog("End the convoy for all \(s.memberUIDs.count) drivers?", isPresented: $confirmEnd) {
                Button("End convoy", role: .destructive) { Task { await store.end() } }
            }
        } else if store.ended {
            Text("Convoy ended.", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s8)
                .background(Color.sodiumDim)
                .task {
                    try? await Task.sleep(for: .seconds(Timing.toast))
                    store.ended = false
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
    @State private var joining = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Sheet(Text(store.state != nil ? "Convoy" : (code.isEmpty ? "Start a convoy" : "Join convoy"))) {
            VStack(alignment: .leading, spacing: Space.s16) {
                if store.state != nil, let c = store.code {
                    Text(verbatim: c).typeStyle(.readoutL).foregroundStyle(Color.chalk)
                    if let url = Route.joinConvoy(code: c).shareURL {
                        ShareLink(item: url) { Text("Share invite", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.sodium) }
                    }
                    if !friends.isEmpty {
                        SectionLabel("INVITE FRIENDS")
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
                    }
                    PrimaryButton(invited.isEmpty ? "Done" : "Invite friends") {
                        if let id = store.state?.id, !invited.isEmpty {
                            let users = Array(invited)
                            Task { try? await store.env.gateway.inviteToConvoy(id, users: users) }
                        }
                        dismiss()
                    }
                } else if !code.isEmpty || joining {
                    Field("Code", text: $code, prompt: "6 characters", limit: 6).textInputAutocapitalization(.characters)
                    Text("Everyone in the convoy sees your exact location until you leave.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                    PrimaryButton("Join convoy", isLoading: working) {
                        run { try await store.join(code: code); dismiss() }
                    }
                    .disabled(code.count != 6)
                } else {
                    Field("Name", text: $name, limit: 40)
                    Field("Destination", text: $place, prompt: "Optional: where you're headed")
                        .onSubmit { findDestination() }
                    if let destination {
                        Text("Heading to \(destination.name)", bundle: .module).typeStyle(.sub).foregroundStyle(Color.go)
                    }
                    Text("Everyone in the convoy sees your exact location until you leave.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                    PrimaryButton("Start convoy", isLoading: working) { run { try await store.create(name: name, destination: destination) } }
                    QuietButton("Join with code") { joining = true }
                }
                if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium])
        .task {
            // Roll out (MEET-13) joins before opening this sheet with the code: show the invite, not the join form.
            if store.state == nil, !code.isEmpty { await store.adopt(code: code) }
            if name.isEmpty, let p = try? await store.env.profiles.myProfile() { name = "\(p.displayName)'s convoy" }
            friends = (try? await store.env.friends.friends()) ?? []
        }
    }

    /// Resolves the typed place into the convoy's destination (first local search hit).
    private func findDestination() {
        guard !place.isEmpty else { destination = nil; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let c = item.placemark.coordinate
            let name = item.name ?? ""
            MainActor.assumeIsolated {
                destination = ConvoyDestination(coordinate: Coordinate(latitude: c.latitude, longitude: c.longitude), name: name)
            }
        }
    }

    private func run(_ body: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await body() } catch WaypointsError.notFound {
                error = "No convoy with that code."
            } catch {
                self.error = "Couldn't reach the convoy. Check your connection and try again."
            }
            working = false
        }
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
