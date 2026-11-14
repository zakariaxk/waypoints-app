import Core
import EventKit
import DesignSystem
import MapKit
import SwiftUI

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
    @State private var hostTeam: Team?
    @State private var details = ""
    @State private var showDetails = false
    @State private var recurrence: MeetRecurrence?
    @State private var destName = ""
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
            _recurrence = State(initialValue: m.recurrence); _destName = State(initialValue: m.destination?.name ?? "")
        }
    }

    private static let repeatOptions: [MeetRecurrence?] = [nil, .weekly, .biweekly, .monthly]

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
                    Text("Repeats").typeStyle(.foot).foregroundStyle(Color.dust)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s8) {
                            ForEach(Self.repeatOptions, id: \.self) { r in
                                Chip(MeetFormat.recurrenceTitle(r), isSelected: recurrence == r) { recurrence = r }
                            }
                        }
                    }
                    if kind == .cruise {
                        Field("Rolling out to", text: $destName, prompt: "Where does the cruise end?", limit: 80)
                    }
                    Text("Who can see it").typeStyle(.foot).foregroundStyle(Color.dust)
                    SegmentedSwitch(selection: $visibility, options: [(.public, "Everyone"), (.friends, "Friends")]
                                    + (hostTeam.map { [(MeetVisibility.team, LocalizedStringKey($0.tag))] } ?? []))
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
        .task {
            // The first team where the user may host meets (plan 10.4 E1).
            for team in (try? await env.teams.myTeams()) ?? [] {
                if (try? await env.teams.myPermissions(in: team.id).contains(.hostMeets)) == true { hostTeam = team; break }
            }
        }
    }

    private func resolvePlace() {
        let loc = CLLocation(latitude: center.latitude, longitude: center.longitude)
        CLGeocoder().reverseGeocodeLocation(loc) { marks, _ in
            let name = marks?.first.map { $0.name ?? $0.locality ?? "" } ?? ""
            MainActor.assumeIsolated { if place.isEmpty || editing == nil { place = name } }
        }
    }

    /// The cruise's end point (MEET-13): the existing one when the name is unchanged, else geocoded near the meet.
    private func destination() async -> ConvoyDestination?? {
        let name = destName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .cruise, !name.isEmpty else { return .some(nil) }
        if let d = editing?.destination, d.name == name { return d }
        guard let c = await Self.locate(name, near: center) else { return nil }
        return ConvoyDestination(coordinate: c, name: name)
    }

    private static func locate(_ query: String, near: CLLocationCoordinate2D) async -> Coordinate? {
        await withCheckedContinuation { (done: CheckedContinuation<Coordinate?, Never>) in
            let region = CLCircularRegion(center: near, radius: 150_000, identifier: "meet")
            CLGeocoder().geocodeAddressString(query, in: region) { marks, _ in
                let c = marks?.first?.location?.coordinate
                done.resume(returning: c.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) })
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            guard let dest = await destination() else {
                error = "Couldn't find that place. Try a fuller name or address."
                failed += 1
                saving = false
                return
            }
            let draft = MeetDraft(title: title, kind: kind, coordinate: Coordinate(latitude: center.latitude, longitude: center.longitude),
                                  placeName: place, startsAt: startsAt, endsAt: endsAt, details: details, visibility: visibility,
                                  teamID: visibility == .team ? hostTeam?.id : nil, recurrence: recurrence, destination: dest)
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
    @State private var askGoing = false
    @State private var addNote = false
    @State private var shareCard: UIImage?
    @State private var rolling = false
    @State private var rollError: String?
    @Environment(\.displayScale) private var displayScale
    @State private var confirmCancel = false
    @State private var editing = false
    @State private var showGoing = false
    @State private var goingPeople: [Profile] = []
    @State private var done = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let m = meet {
                header(m)
                if m.cancelledAt == nil { rsvpControl }
                if let dest = m.destination, canRollOut(m) {
                    PrimaryButton("Roll out", isLoading: rolling) { rollOut(m, to: dest) }
                    if let rollError { Text(verbatim: rollError).typeStyle(.foot).foregroundStyle(Color.brake) }
                }
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
        .task(id: meet) {
            guard let meet, meet.cancelledAt == nil else { return }
            shareCard = await MeetShareCard.render(meet, scale: displayScale)
        }
        .sheet(isPresented: $askGoing) {
            GoingSheet(cars: cars, askCar: cars.count > 1, askRemind: MeetReminder.answer(for: meetID) == nil) { car, remind in
                if let remind { MeetReminder.setAnswer(remind, for: meetID) }
                rsvp(.going, car: car)
            }
        }
        .confirmationDialog("Cancel this meet? \(rsvps.count) people who RSVP'd will be told.", isPresented: $confirmCancel,
                            titleVisibility: .visible) {
            if meet?.seriesID != nil {
                Button("This meet", role: .destructive) { cancel(following: false) }
                Button("This and every one after", role: .destructive) { cancel(following: true) }
            } else {
                Button("Cancel meet", role: .destructive) { cancel(following: false) }
            }
        }
        .sheet(isPresented: $showGoing) {
            Sheet(Text("Who's going")) {
                ScrollView {
                    ForEach(goingPeople) { p in
                        let rsvp = rsvps.first { $0.userID == p.userID }
                        let car = rsvp?.carID.flatMap { id in goingCars.first { $0.id == id } }
                        Button { showGoing = false; env.router.open(.profile(p.userID)) } label: {
                            Row(Text(verbatim: p.displayName), subtitle: car.map { Text(verbatim: $0.shortLabel) },
                                leading: { Avatar(name: p.displayName, size: .s40) },
                                trailing: {
                                    // NAV-15: set while they navigate here. No position, only the label.
                                    if rsvp?.isOnTheWay() == true {
                                        Text("On the way").typeStyle(.label).foregroundStyle(Color.go)
                                    }
                                })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .task { goingPeople = (try? await env.profiles.profiles(rsvps.filter { $0.status == .going }.map(\.userID))) ?? [] }
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
                    if let url = URL(string: "waypoints://meet/\(m.id)") {
                        if let shareCard {
                            // LINK-5: the card image with the link alongside it.
                            ShareLink("Share", item: Image(uiImage: shareCard), message: Text(verbatim: url.absoluteString),
                                      preview: SharePreview(m.title, image: Image(uiImage: shareCard)))
                        } else {
                            ShareLink("Share", item: url)
                        }
                    }
                    Button("Add to Calendar") { Task { await addToCalendar(m) } }
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
            if let repeats = MeetFormat.repeats(m) {
                Text(verbatim: repeats).typeStyle(.sub).foregroundStyle(Color.dust)
            }
            if let dest = m.destination {
                Text("Rolling out to \(dest.name)").typeStyle(.sub).foregroundStyle(Color.dust)
            }
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
            case 0:
                if cars.count > 1 || MeetReminder.answer(for: meetID) == nil { askGoing = true } else { rsvp(.going, car: cars.first?.id) }
            case 1: rsvp(.maybe, car: nil)
            default:
                mine = nil
                MeetReminder.cancel(meetID)
                Task { try? await env.meets.clearRSVP(for: meetID); await load() }
            }
        }), options: [(0, "Going"), (1, "Maybe"), (2, "Can't")])
    }

    @ViewBuilder private var going: some View {
        let count = rsvps.filter { $0.status == .going }.count
        if count > 0 {
            Button { showGoing = true } label: {
                Text("Who's going · \(count)").typeStyle(.label).foregroundStyle(Color.dust)
            }
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

    /// Write-only calendar access is enough to add one event.
    private func addToCalendar(_ m: Meet) async {
        let store = EKEventStore()
        guard (try? await store.requestWriteOnlyAccessToEvents()) == true else { return }
        let event = EKEvent(eventStore: store)
        event.title = m.title
        event.startDate = m.startsAt
        event.endDate = m.endsAt
        event.location = m.placeName
        event.url = URL(string: "waypoints://meet/\(m.id)")
        event.calendar = store.defaultCalendarForNewEvents
        try? store.save(event, span: .thisEvent)
        done += 1
    }

    private func rsvp(_ status: RSVPStatus, car: CarID?) {
        mine = status
        Task {
            try? await env.meets.setRSVP(status, for: meetID, car: car)
            done += 1
            await load()
        }
    }

    private func cancel(following: Bool) {
        Task {
            if following { try? await env.gateway.cancelMeetAndFollowing(meetID) } else { try? await env.gateway.cancelMeet(meetID) }
            MeetReminder.cancel(meetID)
            await load()
        }
    }

    /// MEET-13: the host of a cruise with a destination sees "Roll out" from shortly before the start.
    private func canRollOut(_ m: Meet) -> Bool {
        m.hostID == me && m.kind == .cruise && m.cancelledAt == nil
            && m.startsAt.addingTimeInterval(-MeetReminder.lead / 2) <= .now && .now < m.endsAt
    }

    /// Starts a convoy named for the meet, headed to its destination, invites everyone Going, then opens it.
    private func rollOut(_ m: Meet, to dest: ConvoyDestination) {
        rolling = true
        rollError = nil
        Task {
            do {
                let invite = try await env.gateway.createConvoy(name: String(m.title.prefix(40)), destination: dest)
                let going = rsvps.filter { $0.status == .going && $0.userID != me }.map(\.userID)
                if !going.isEmpty { try? await env.gateway.inviteToConvoy(invite.id, users: going) }
                done += 1
                env.router.open(.joinConvoy(code: invite.joinCode))
            } catch {
                rollError = "Couldn't start the convoy. Check your connection and try again."
            }
            rolling = false
        }
    }

    private func load() async {
        me = await env.auth.currentSession()?.userID
        guard let m = try? await env.meets.meet(meetID) else { return }
        meet = m
        host = try? await env.profiles.profile(m.hostID)
        rsvps = (try? await env.meets.rsvps(for: meetID)) ?? []
        mine = (try? await env.meets.myRSVP(for: meetID))?.status
        await MeetReminder.sync(m, going: mine == .going)
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
