import Core
import DesignSystem
import MapKit
import SwiftUI
import UserNotifications

/// Meets (plan 10.4): map layer, sheet section, "Start a meet", routes `meet` and `createMeet`.
public enum MeetsFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerMapLayer(MeetsLayer(env: env))
        registry.registerMapSheetSection(MeetsSection(env: env))
        registry.registerMapAction(StartMeetAction())
        registry.registerRoute(.meet, presentation: .sheet) { route in
            guard case let .meet(id) = route else { return nil }
            return AnyView(NavigationStack { ScrollView { MeetDetail(env: env, meetID: id) } .background(Color.tarmac) }
                .presentationDetents([.medium, .large]).sheetChrome())
        }
        registry.registerRoute(.createMeet, presentation: .sheet) { route in
            guard case let .createMeet(c) = route else { return nil }
            return AnyView(CreateMeet(env: env, start: c))
        }
    }
}

/// Asks for notification permission once, at a moment that gives it a reason (plan 10.2).
@MainActor
func askForNotifications() {
    let key = "notifications.asked"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
        if granted { Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() } }
    }
}

enum MeetFormat {
    static func when(_ m: Meet) -> String {
        let cal = Calendar.current
        let time = m.startsAt.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(m.startsAt) { return cal.component(.hour, from: m.startsAt) >= 17 ? "Tonight \(time)" : "Today \(time)" }
        if cal.isDateInTomorrow(m.startsAt) { return "Tomorrow \(time)" }
        return m.startsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
    static func kindTitle(_ k: MeetKind) -> LocalizedStringKey {
        switch k { case .meet: "Meet"; case .cruise: "Cruise"; case .hangout: "Hangout"; case .trackDay: "Track day"; case .show: "Show" }
    }
}

struct MeetsLayer: MapLayerProvider {
    let env: AppEnvironment
    var id: String { "meets" }

    func items(in region: MapRegion) -> AsyncStream<[MapItem]> {
        AsyncStream { c in
            let task = Task {
                let meets = (try? await env.meets.meets(in: region)) ?? []
                c.yield(meets.filter { $0.cancelledAt == nil }.map { m in
                    MapItem(id: m.id.description, coordinate: m.coordinate, glyph: .meet(m.kind),
                            tint: m.isHappening() ? .go : .sodium,
                            title: m.startsAt.formatted(date: .omitted, time: .shortened), priority: 5)
                })
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor func detail(for item: MapItem) -> AnyView? {
        MeetID(string: item.id).map { AnyView(MeetDetail(env: env, meetID: $0)) }
    }
}

struct MeetsSection: MapSheetSection {
    let env: AppEnvironment
    var id: String { "meets" }
    var order: Int { 10 }
    @MainActor func view(region: MapRegion) -> AnyView { AnyView(MeetsSectionView(env: env, region: region)) }
}

struct MeetsSectionView: View {
    let env: AppEnvironment
    let region: MapRegion
    @State private var meets: [Meet] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !meets.isEmpty {
                SectionLabel("MEETS")
                ForEach(meets.sorted { $0.startsAt < $1.startsAt }.prefix(6)) { m in
                    Button { env.router.open(.meet(m.id)) } label: {
                        Row(Text(verbatim: m.title), subtitle: Text(verbatim: m.placeName), leading: {
                            MeetPin(kind: m.kind.rawValue, live: m.isHappening()).scaleEffect(0.7)
                                .frame(width: Size.Marker.meetPin, height: Size.Marker.meetPin)
                        }, trailing: { Text(verbatim: MeetFormat.when(m)).typeStyle(.readoutS) })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .task(id: region) { meets = ((try? await env.meets.meets(in: region)) ?? []).filter { $0.cancelledAt == nil } }
    }
}

struct StartMeetAction: MapAction {
    var id: String { "startMeet" }
    var title: String { String(localized: "Start a meet") }
    var symbol: String { "car.2" }
    var order: Int { 20 }
    @MainActor func perform(at coordinate: Coordinate, router: any Router) { router.open(.createMeet(coordinate)) }
}

// MARK: E1 Start a meet

struct CreateMeet: View {
    let env: AppEnvironment
    let start: Coordinate?
    var editing: Meet?
    @Environment(\.dismiss) private var dismiss
    @State private var center: CLLocationCoordinate2D
    @State private var place = ""
    @State private var title = ""
    @State private var kind: MeetKind = .meet
    @State private var when = 1
    @State private var startsAt = Date.now
    @State private var endsAt = Date.now.addingTimeInterval(7200)
    @State private var visibility: MeetVisibility = .public
    @State private var details = ""
    @State private var showDetails = false
    @State private var saving = false
    @State private var error: String?
    @State private var failed = 0
    @State private var done = 0
    @State private var position: MapCameraPosition

    init(env: AppEnvironment, start: Coordinate?, editing: Meet? = nil) {
        self.env = env; self.start = start; self.editing = editing
        let c = editing?.coordinate ?? start ?? Coordinate(latitude: 39.95, longitude: -75.16)
        _center = State(initialValue: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude))
        _position = State(initialValue: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                                                                   latitudinalMeters: 800, longitudinalMeters: 800)))
        if let m = editing {
            _title = State(initialValue: m.title); _kind = State(initialValue: m.kind); _place = State(initialValue: m.placeName)
            _startsAt = State(initialValue: m.startsAt); _endsAt = State(initialValue: m.endsAt); _when = State(initialValue: 2)
            _details = State(initialValue: m.details); _visibility = State(initialValue: m.visibility)
        }
    }

    private static var tonight8: Date {
        let d = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now) ?? .now
        return d < .now ? d.addingTimeInterval(86400) : d
    }

    var body: some View {
        Sheet(Text(editing == nil ? "Start a meet" : "Edit meet")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Map(position: $position, interactionModes: [.pan, .zoom]) {}
                        .overlay { Image(systemName: "mappin").font(.title).foregroundStyle(Color.sodium).offset(y: -Space.s12) }
                        .onMapCameraChange(frequency: .onEnd) { ctx in center = ctx.region.center; resolvePlace() }
                        .frame(height: Size.row * 3)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.r20))
                        .environment(\.colorScheme, .dark)
                    Field("Place", text: $place, prompt: "Where is it?", limit: 80)
                    Field("What is it?", text: $title, prompt: "Wawa and chill", limit: 50)
                    HStack(spacing: Space.s8) {
                        ForEach(MeetKind.allCases, id: \.self) { k in
                            Chip(MeetFormat.kindTitle(k), isSelected: kind == k) { kind = k }
                        }
                    }
                    Text("When").typeStyle(.foot).foregroundStyle(Color.dust)
                    HStack(spacing: Space.s8) {
                        Chip("Now", isSelected: when == 0) { when = 0; startsAt = .now; endsAt = .now.addingTimeInterval(7200) }
                        Chip("Tonight 8 PM", isSelected: when == 1) {
                            when = 1; startsAt = Self.tonight8; endsAt = Self.tonight8.addingTimeInterval(7200)
                        }
                        Chip("Pick a time", isSelected: when == 2) { when = 2 }
                    }
                    if when == 2 {
                        DatePicker("Starts", selection: $startsAt, in: Date.now...).tint(.sodium).foregroundStyle(Color.chalk)
                            .onChange(of: startsAt) { endsAt = startsAt.addingTimeInterval(7200) }
                    }
                    DatePicker("Ends", selection: $endsAt, in: startsAt...).tint(.sodium).foregroundStyle(Color.chalk)
                    Text("Who can see it").typeStyle(.foot).foregroundStyle(Color.dust)
                    SegmentedSwitch(selection: $visibility, options: [(.public, "Everyone"), (.friends, "Friends")])
                    if showDetails {
                        Field("Details", text: $details, limit: 500, axis: .vertical)
                    } else {
                        QuietButton("Add details") { showDetails = true }
                    }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton(editing == nil ? "Start meet" : "Save meet", isLoading: saving) { save() }
                        .disabled(title.isEmpty)
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
        .haptic(.fail, trigger: failed)
        .haptic(.done, trigger: done)
        .onAppear {
            if editing == nil { startsAt = Self.tonight8; endsAt = Self.tonight8.addingTimeInterval(7200) }
            resolvePlace()
        }
    }

    private func resolvePlace() {
        let loc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
            let name = marks?.first.map { $0.name ?? $0.locality ?? "" } ?? ""
            MainActor.assumeIsolated { if place.isEmpty || editing == nil { place = name } }
        }
    }

    private func save() {
        saving = true
        error = nil
        let draft = MeetDraft(title: title, kind: kind, coordinate: Coordinate(latitude: center.latitude, longitude: center.longitude),
                              placeName: place, startsAt: startsAt, endsAt: endsAt, details: details, visibility: visibility)
        Task {
            do {
                let meet = if let editing { try await env.gateway.updateMeet(editing.id, draft) } else { try await env.gateway.createMeet(draft) }
                done += 1
                dismiss()
                if editing == nil { env.router.open(.meet(meet.id)) }
            } catch WaypointsError.rateLimited {
                error = "You've started 3 meets today. That's the limit."
                failed += 1
            } catch {
                self.error = "Couldn't start the meet. Check your connection and try again."
                failed += 1
            }
            saving = false
        }
    }
}

// MARK: E2 Meet

struct MeetDetail: View {
    let env: AppEnvironment
    let meetID: MeetID
    @State private var meet: Meet?
    @State private var host: Profile?
    @State private var rsvps: [MeetRSVP] = []
    @State private var mine: RSVPStatus?
    @State private var me: UserID?
    @State private var cars: [Car] = []
    @State private var goingCars: [Car] = []
    @State private var notes: [VenueNote] = []
    @State private var askCar = false
    @State private var addNote = false
    @State private var confirmCancel = false
    @State private var editing = false
    @State private var done = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let m = meet {
                header(m)
                if m.cancelledAt == nil { rsvpControl }
                going
                venue
                if !m.details.isEmpty { Text(verbatim: m.details).typeStyle(.body).foregroundStyle(Color.chalk) }
                PrimaryButton("Directions") { env.router.open(.navigate(to: m.coordinate, name: m.placeName)) }
            } else {
                SkeletonRow(); SkeletonRow()
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s24)
        .haptic(.done, trigger: done)
        .task { await load() }
        .confirmationDialog("Which car are you bringing?", isPresented: $askCar) {
            ForEach(cars) { car in
                Button(car.shortLabel) { rsvp(.going, car: car.id) }
            }
            Button("Not sure yet") { rsvp(.going, car: nil) }
        }
        .confirmationDialog("Cancel this meet? \(rsvps.count) people who RSVP'd will be told.", isPresented: $confirmCancel) {
            Button("Cancel meet", role: .destructive) {
                Task { try? await env.gateway.cancelMeet(meetID); await load() }
            }
        }
        .sheet(isPresented: $addNote) { VenueNoteSheet(env: env, at: meet?.coordinate) { Task { await load() } } }
        .sheet(isPresented: $editing) { if let meet { CreateMeet(env: env, start: nil, editing: meet) } }
    }

    private func header(_ m: Meet) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                MeetPin(kind: m.kind.rawValue, live: m.isHappening())
                Spacer()
                Menu {
                    if let url = URL(string: "waypoints://meet/\(m.id)") { ShareLink("Share", item: url) }
                    if m.hostID == me {
                        Button("Edit") { editing = true }
                        Button("Cancel meet", role: .destructive) { confirmCancel = true }
                    } else {
                        Button("Report") { env.router.open(.reportContent(ContentRef(kind: .meet, id: m.id.description))) }
                    }
                } label: { Image.symbol(Symbol.more).frame(width: Size.hitTarget, height: Size.hitTarget) }
            }
            if m.cancelledAt != nil {
                Text("Cancelled").typeStyle(.bodyStrong).foregroundStyle(Color.brake)
            } else if m.isHappening() {
                Text("Happening now").typeStyle(.bodyStrong).foregroundStyle(Color.go)
            }
            Text(verbatim: m.title).typeStyle(.title).foregroundStyle(Color.chalk)
            Text(verbatim: MeetFormat.when(m)).typeStyle(.readoutM).foregroundStyle(Color.chalk)
            Text(verbatim: m.placeName).typeStyle(.sub).foregroundStyle(Color.dust)
            if let host {
                Button { env.router.open(.profile(host.userID)) } label: {
                    HStack(spacing: Space.s8) {
                        Avatar(name: host.displayName, size: .s28)
                        Text("Hosted by \(host.displayName)").typeStyle(.sub).foregroundStyle(Color.chalk)
                    }
                }
            }
        }
    }

    private var rsvpControl: some View {
        SegmentedSwitch(selection: Binding(get: { mine.map { $0 == .going ? 0 : 1 } ?? 2 }, set: { v in
            switch v {
            case 0: if cars.count > 1 { askCar = true } else { rsvp(.going, car: cars.first?.id) }
            case 1: rsvp(.maybe, car: nil)
            default:
                mine = nil
                Task { try? await env.meets.clearRSVP(for: meetID); await load() }
            }
        }), options: [(0, "Going"), (1, "Maybe"), (2, "Can't")])
    }

    @ViewBuilder private var going: some View {
        let count = rsvps.filter { $0.status == .going }.count
        if count > 0 {
            Text("Who's going · \(count)").typeStyle(.label).foregroundStyle(Color.dust)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s12) {
                    ForEach(goingCars) { car in
                        Button { env.router.open(.car(car.id)) } label: { CarBadge(car.shortLabel, paint: car.colorHex.flatMap { Color(paintHex: $0) } ?? .dust) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var venue: some View {
        if let n = notes.first {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Entrance: \(n.entrance.rawValue)").typeStyle(.sub).foregroundStyle(Color.chalk)
                Text("Lot: \(n.lotSize.rawValue)").typeStyle(.sub).foregroundStyle(Color.chalk)
                Text(n.lit ? "Lit: yes" : "Lit: no").typeStyle(.sub).foregroundStyle(Color.chalk)
            }
        }
        QuietButton("Add what you know") { addNote = true }
    }

    private func rsvp(_ status: RSVPStatus, car: CarID?) {
        mine = status
        if status == .going { askForNotifications() }
        Task {
            try? await env.meets.setRSVP(status, for: meetID, car: car)
            done += 1
            await load()
        }
    }

    private func load() async {
        me = await env.auth.currentSession()?.userID
        guard let m = try? await env.meets.meet(meetID) else { return }
        meet = m
        host = try? await env.profiles.profile(m.hostID)
        rsvps = (try? await env.meets.rsvps(for: meetID)) ?? []
        mine = (try? await env.meets.myRSVP(for: meetID))?.status
        if let me { cars = (try? await env.garage.cars(of: me)) ?? [] }
        var list: [Car] = []
        for r in rsvps where r.status == .going {
            if let id = r.carID, let c = try? await env.garage.car(id) { list.append(c) }
        }
        goingCars = list
        notes = (try? await env.meets.venueNotes(near: m.coordinate, meters: 150)) ?? []
    }
}

struct VenueNoteSheet: View {
    let env: AppEnvironment
    let at: Coordinate?
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entrance: EntranceGrade = .flat
    @State private var lot: LotSize = .medium
    @State private var lit = true
    @State private var note = ""

    var body: some View {
        Sheet(Text("Add what you know")) {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Entrance").typeStyle(.foot).foregroundStyle(Color.dust)
                SegmentedSwitch(selection: $entrance, options: [(.flat, "Flat"), (.moderate, "Moderate"), (.steep, "Steep")])
                Text("Lot").typeStyle(.foot).foregroundStyle(Color.dust)
                SegmentedSwitch(selection: $lot, options: [(.small, "Small"), (.medium, "Medium"), (.large, "Large")])
                Row(Text("Lit at night"), showsDivider: false, trailing: { Toggle("", isOn: $lit).labelsHidden().tint(.sodium) })
                Field("Note", text: $note, prompt: "Optional", limit: 120)
                PrimaryButton("Save") {
                    guard let at else { return }
                    Task {
                        guard let me = await env.auth.currentSession()?.userID else { return }
                        _ = try? await env.meets.addVenueNote(VenueNote(authorID: me, coordinate: at, entrance: entrance,
                                                                        lotSize: lot, lit: lit, note: note.isEmpty ? nil : note))
                        onSave()
                        dismiss()
                    }
                }
            }
            .padding(Space.margin)
        }
        .presentationDetents([.medium, .large])
    }
}
