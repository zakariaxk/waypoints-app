import Core
import DesignSystem
import MapKit
import Network
import SwiftUI

// MARK: M7 Driver peek

struct DriverPeek: View {
    let model: MapModel
    let entity: Entity
    @State private var whyOpen = false
    @State private var confirmRemove = false

    var body: some View {
        if let friend = model.friend(uid: entity.uid), entity.info?.relation != .nearby {
            friendPeek(friend)
        } else {
            strangerPeek
        }
    }

    private func friendPeek(_ f: Friend) -> some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack(spacing: Space.s12) {
                Avatar(name: f.profile.displayName, size: .s64)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(verbatim: f.profile.displayName).typeStyle(.title).foregroundStyle(Color.chalk)
                    Text(verbatim: "@\(f.profile.handle)").typeStyle(.sub).foregroundStyle(Color.dust)
                    if let car = f.primaryCar {
                        CarBadge(car.shortLabel, icon: f.profile.markerIcon, paint: car.paint)
                    }
                }
                Spacer()
                Menu {
                    Button("View profile") { model.env.router.open(.profile(f.profile.userID)) }
                    Button("Invite to convoy") { model.inviteToConvoy(f.profile.userID) }
                    Button("Remove friend", role: .destructive) { confirmRemove = true }
                    Button("Block", role: .destructive) { Task { try? await model.env.safety.block(f.profile.userID) } }
                    Button("Report") { model.env.router.open(.reportContent(.user(f.profile.userID))) }
                } label: { Image.symbol(Symbol.more).frame(width: Size.hitTarget, height: Size.hitTarget) }
                    .accessibilityLabel(Text("More"))
            }
            Text(verbatim: entity.tier == .approximate
                 ? "\(model.distanceLine(to: entity.coordinate)) · approximate"
                 : "\(model.distanceLine(to: entity.coordinate)) · updated \(entity.staleness < 30 ? "now" : "\(Int(entity.staleness / 60)) min ago")")
                .typeStyle(.readoutS).foregroundStyle(Color.dust)
            HStack(spacing: Space.s12) {
                PrimaryButton("Directions") {
                    model.env.router.open(.navigate(to: entity.coordinate, name: f.profile.displayName))
                }
                SecondaryButton("Message") {
                    Task {
                        if let thread = try? await model.env.messages.openThread(with: f.profile.userID, listing: nil) {
                            model.env.router.open(.thread(thread.id))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .confirmationDialog("Remove \(f.profile.displayName) as a friend?", isPresented: $confirmRemove) {
            Button("Remove friend", role: .destructive) { Task { try? await model.env.friends.remove(f.profile.userID) } }
        }
    }

    private var strangerPeek: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack(spacing: Space.s12) {
                SilhouetteIcon(entity.info?.markerIcon ?? "coupe", paint: .dust).frame(width: Size.Marker.you, height: Size.Marker.you)
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("A driver nearby").typeStyle(.title).foregroundStyle(Color.chalk)
                    Text("Approximate location").typeStyle(.sub).foregroundStyle(Color.dust)
                }
            }
            QuietButton("Why can't I see more?") { whyOpen.toggle() }
            if whyOpen {
                Text("Drivers who aren't your friends choose whether to show up at all, and when they do, only a half-mile area is shared. Your own setting works the same way.")
                    .typeStyle(.sub).foregroundStyle(Color.dust)
                QuietButton("Your privacy settings") { model.env.router.open(.settingsPrivacy) }
            }
        }
        .padding(.horizontal, Space.margin)
    }
}

// MARK: M8 Layers

struct LayersSheet: View {
    @Bindable var model: MapModel
    let openMarkerPicker: () -> Void

    var body: some View {
        Sheet(Text("Layers")) {
            ScrollView {
                VStack(spacing: 0) {
                    toggle("Friends", "friends")
                    toggle("Drivers nearby", "nearby")
                    ForEach(model.registry.mapLayers, id: \.id) { provider in
                        toggle(LocalizedStringKey(MapIconSet.title(provider.id)), provider.id)
                    }
                    toggle("Traffic", "traffic")
                    SectionLabel("YOUR MARKER")
                    Button(action: openMarkerPicker) {
                        Row(Text("Icon and trail"), leading: {
                            SilhouetteIcon(model.profile?.markerIcon ?? "coupe", paint: model.primaryCar?.paint ?? .dust)
                                .frame(width: Size.Marker.stranger, height: Size.Marker.stranger)
                        }, trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func toggle(_ title: LocalizedStringKey, _ key: String) -> some View {
        Row(Text(title), trailing: {
            Toggle("", isOn: Binding(get: { model.isOn(key) }, set: { model.layers[key] = $0 })).labelsHidden().tint(.sodium)
        })
    }
}

// MARK: M10 Marker picker

struct MarkerPicker: View {
    let model: MapModel
    @State private var tab = 0
    @State private var progress: [AchievementProgress] = []
    @State private var requirement: String?
    @State private var tick = 0

    /// Which key unlocks which icon or trail (plan 9.8 and W5-5).
    static let unlocks: [String: (key: String, text: String)] = [
        "lowrider": ("first_meet", "First meet: RSVP Going and show up."),
        "safety_car": ("host_3", "Host 3 meets with at least 5 people checked in."),
        "rally": ("reports_10", "Rally: get 10 reports confirmed."),
        "lifted_truck": ("reports_50", "Get 50 reports confirmed."),
        "shooting_brake": ("spots_25", "Spot 25 different models."),
        "woody_wagon": ("spots_100", "Spot 100 different models."),
        "targa": ("roads_5", "Rate 5 roads."),
        "restomod": ("build_10", "Log 10 timeline entries on one car."),
        "wide_body": ("showdown_top10", "Get a car into the weekly top 10 of its class."),
        "flatbed": ("convoy_lead", "Lead a convoy of 5 or more to its destination."),
        "drift": ("strip_12s", "Run a virtual quarter mile under 12 seconds."),
        "time_attack": ("strip_10s", "Run a virtual quarter mile under 10 seconds."),
        "dually": ("teams_join", "Join a team."), "fastback_classic": ("meets_5", "Go to 5 meets."),
        "microcar": ("friends_5", "Add 5 friends."), "van_camper": ("convoy_3", "Drive in 3 convoys."),
        "ute": ("listing_1", "List something in the market."), "gt_wing_hatch": ("showdown_50", "Judge 50 Showdown pairs."),
        "rat_rod": ("build_25", "Log 25 timeline entries."), "box_truck": ("venue_5", "Add 5 venue notes."),
        "dash": ("reports_1", "Post your first report."), "double": ("meets_1", "Go to a meet."),
        "chevrons": ("convoy_1", "Drive in a convoy."), "dots": ("spots_5", "Spot 5 models."),
        "checker": ("strip_1", "Run the strip once."), "tread": ("roads_1", "Rate a road."),
        "comet": ("posts_5", "Post 5 videos."),
    ]

    var body: some View {
        Sheet(Text("Your marker")) {
            VStack(spacing: Space.s16) {
                VehicleMarker(icon: model.profile?.markerIcon ?? "coupe", paint: model.primaryCar?.paint ?? .dust, role: .you)
                    .scaleEffect(2)
                    .frame(height: Size.Marker.you * 2.5)
                    .frame(maxWidth: .infinity)
                    .background(Color.asphalt, in: RoundedRectangle(cornerRadius: Radius.r20))
                if let requirement {
                    Text(verbatim: requirement).typeStyle(.sub).foregroundStyle(Color.sodium)
                }
                SegmentedSwitch(selection: $tab, options: [(0, "Icon"), (1, "Trail")])
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: Space.s16) {
                        ForEach(tab == 0 ? MapGlyph.freeVehicles.map(\.name) + MapIconSet.earnedVehicles : MapIconSet.trails,
                                id: \.self) { name in cell(name) }
                    }
                }
            }
            .padding(.horizontal, Space.margin)
        }
        .presentationDetents([.large])
        .haptic(.tick, trigger: tick)
        .task { progress = (try? await model.env.progress.myProgress()) ?? [] }
    }

    private func unlocked(_ name: String) -> Bool {
        guard let u = Self.unlocks[name] else { return true }
        return progress.first { $0.key == u.key }?.earnedAt != nil
    }

    private func cell(_ name: String) -> some View {
        let open = unlocked(name)
        return Button {
            if open {
                tick += 1
                requirement = nil
                let update = tab == 0 ? ProfileUpdate(markerIcon: name) : ProfileUpdate(markerTrail: name)
                Task { _ = try? await model.env.profiles.updateMyProfile(update) }
            } else if let u = Self.unlocks[name] {
                let p = progress.first { $0.key == u.key }
                requirement = p.map { "\(u.text) You're at \($0.current) of \($0.target)." } ?? u.text
            }
        } label: {
            VStack(spacing: Space.s4) {
                ZStack(alignment: .bottomTrailing) {
                    if tab == 0 {
                        SilhouetteIcon(name, paint: open ? (model.primaryCar?.paint ?? .chalk) : .curb)
                            .frame(width: Size.Marker.friend, height: Size.Marker.friend)
                    } else {
                        Text(verbatim: MapIconSet.title(name)).typeStyle(.foot).foregroundStyle(open ? Color.chalk : Color.gravel)
                            .frame(height: Size.Marker.friend)
                    }
                    if !open { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Color.gravel) }
                }
                if tab == 0 {
                    Text(verbatim: MapIconSet.title(name)).typeStyle(.foot).foregroundStyle(Color.dust).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Size.row)
            .background((model.profile?.markerIcon == name || model.profile?.markerTrail == name) ? Color.sodiumDim : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.r12))
        }
        .accessibilityLabel(Text(verbatim: MapIconSet.title(name) + (open ? "" : ", locked")))
    }
}

// MARK: M2 Search

@MainActor
@Observable
final class SearchModel: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" { didSet { completer.queryFragment = query } }
    struct Place: Hashable, Sendable { var title: String; var subtitle: String }
    var results: [Place] = []
    var people: [Profile] = []
    var meets: [Meet] = []
    /// Search needs the network; offline it shows recents only (NAV-1).
    var online = true
    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private var monitor: NWPathMonitor?

    func watchNetwork() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { @Sendable [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor [weak self] in self?.online = ok }
        }
        m.start(queue: .global(qos: .utility))
        monitor = m
    }

    func stopWatching() {
        monitor?.cancel()
        monitor = nil
    }

    func configure(region: MapRegion) {
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = MKCoordinateRegion(center: region.center.cl,
                                              span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta))
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = completer.results.prefix(10).map { Place(title: $0.title, subtitle: $0.subtitle) }
        MainActor.assumeIsolated { self.results = r }
    }
}

struct SearchView: View {
    let model: MapModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = SearchModel()
    @State private var upcoming: [Meet] = []
    @State private var savedRoads: [Road] = []
    @FocusState private var focused: Bool
    @AppStorage("map.recents") private var recentsRaw = ""

    private var recents: [String] { recentsRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if search.query.isEmpty {
                        if !recents.isEmpty {
                            SectionLabel("Recent")
                            ForEach(recents.prefix(5), id: \.self) { r in
                                Button { search.query = r } label: { Row(Text(verbatim: r)) }.buttonStyle(RowButtonStyle())
                            }
                        }
                        if !search.online {
                            offlineLine
                        } else {
                            if !upcoming.isEmpty {
                                SectionLabel("Meets tonight")
                                ForEach(upcoming.prefix(3)) { meetRow($0) }
                            }
                            if !savedRoads.isEmpty {
                                SectionLabel("Saved roads")
                                ForEach(savedRoads.prefix(3)) { roadRow($0) }
                            }
                        }
                    } else if !search.online {
                        offlineLine
                    } else {
                        ForEach(search.results, id: \.self) { r in
                            Button { pick(r) } label: {
                                Row(Text(verbatim: r.title), subtitle: Text(verbatim: r.subtitle))
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                        if !search.people.isEmpty {
                            SectionLabel("People")
                            ForEach(search.people) { p in
                                Button {
                                    dismiss()
                                    model.env.router.open(.profile(p.userID))
                                } label: {
                                    Row(Text(verbatim: p.displayName), subtitle: Text(verbatim: "@\(p.handle)"), leading: {
                                        Avatar(name: p.displayName, size: .s40)
                                    })
                                }
                                .buttonStyle(RowButtonStyle())
                            }
                        }
                        let meets = upcoming.filter { $0.title.localizedCaseInsensitiveContains(search.query) }
                        if !meets.isEmpty {
                            SectionLabel("Meets")
                            ForEach(meets) { meetRow($0) }
                        }
                        if search.results.isEmpty && search.people.isEmpty && meets.isEmpty {
                            Text("Nothing found for '\(search.query)'.").typeStyle(.sub).foregroundStyle(Color.dust).padding(Space.margin)
                        }
                    }
                }
            }
            .background(Color.asphalt.ignoresSafeArea())
            .safeAreaInset(edge: .top) {
                HStack {
                    Field("Search", text: $search.query, prompt: "Where to?").focused($focused)
                    QuietButton("Cancel") { dismiss() }
                }
                .padding(.horizontal, Space.margin)
                .background(Color.asphalt)
            }
        }
        .onAppear { focused = true; search.configure(region: model.region); search.watchNetwork() }
        .onDisappear { search.stopWatching() }
        .task { upcoming = (try? await model.env.meets.meets(in: model.region)) ?? [] }
        .task {
            guard let me = await model.env.auth.currentSession()?.userID else { return }
            savedRoads = (try? await model.env.roads.roads(by: me)) ?? []
        }
        .task(id: search.query) {
            guard search.query.count >= 2 else { search.people = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            search.people = (try? await model.env.profiles.search(search.query, limit: 5)) ?? []
        }
    }

    private var offlineLine: some View {
        Text("Search needs a connection.").typeStyle(.sub).foregroundStyle(Color.dust).padding(Space.margin)
    }

    /// A saved road opens directions to where it starts.
    private func roadRow(_ r: Road) -> some View {
        Button {
            guard let start = r.path.first else { return }
            dismiss()
            model.env.router.open(.navigate(to: start, name: r.name))
        } label: {
            Row(Text(verbatim: r.name), trailing: {
                Text(verbatim: Self.length(r.lengthMeters)).typeStyle(.readoutS)
            })
        }
        .buttonStyle(RowButtonStyle())
    }

    /// Road length in miles or kilometres by locale (SET-3).
    static func length(_ meters: Int) -> String {
        let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
        return Measurement(value: Double(meters), unit: UnitLength.meters).converted(to: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    private func meetRow(_ m: Meet) -> some View {
        Button {
            dismiss()
            model.env.router.open(.meet(m.id))
        } label: {
            Row(Text(verbatim: m.title), trailing: {
                Text(verbatim: m.startsAt.formatted(date: .omitted, time: .shortened)).typeStyle(.readoutS)
            })
        }
        .buttonStyle(RowButtonStyle())
    }

    private func pick(_ completion: SearchModel.Place) {
        recentsRaw = ([completion.title] + recents.filter { $0 != completion.title }).prefix(5).joined(separator: "\n")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(completion.title) \(completion.subtitle)"
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { return }
            let c = item.placemark.coordinate
            let name = item.name
            MainActor.assumeIsolated {
                dismiss()
                model.env.router.open(.navigate(to: Coordinate(latitude: c.latitude, longitude: c.longitude), name: name))
            }
        }
    }
}
