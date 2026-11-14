import AVFoundation
import Core
import DesignSystem
import MapKit
import Network
import SwiftUI

/// Route preview with low-car scoring (M3) and turn-by-turn guidance (M4). Handles `navigate`.
public enum NavigationFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.navigate, presentation: .fullScreen) { route in
            guard case let .navigate(to, name) = route else { return nil }
            return AnyView(NavigationRoot(env: env, destination: to, name: name))
        }
    }
}

/// One alternate with its clearance hazards.
struct ScoredRoute: Identifiable {
    let id = UUID()
    let route: MKRoute
    var hazards: [Report] = []
    func clearanceHazards(for c: Clearance) -> [Report] {
        hazards.filter { r in
            switch c {
            case .stock: false
            case .lowered: [.steepEntrance, .speedBump].contains(r.kind)
            case .slammed: r.kind.affectsClearance
            }
        }
    }
}

@MainActor
@Observable
final class NavigationModel {
    let env: AppEnvironment
    let destination: Coordinate
    let name: String?
    var routes: [ScoredRoute] = []
    var selected = 0
    var cars: [Car] = []
    var carIndex = 0
    var error = false
    var loading = true
    var guiding = false

    // Guidance state
    var stepIndex = 0
    var toManeuver: Double = 0
    var remaining: Double = 0
    var speed: Double = 0
    var offRoute = false
    var rerouting = false
    var arrived = false
    var hazardAhead: Report?
    /// Metres along the route from here to `hazardAhead`.
    var hazardDistance: Double = 0
    var me: CLLocationCoordinate2D?
    var heading: Double = 0
    /// Network reachability (NAV-12). Offline, guidance keeps the loaded route and does not reroute.
    var online = true
    /// The convoy this device is in, if any (NAV-13).
    var convoyID: ConvoyID?
    var sharedWithConvoy = false
    var shareFailed = false
    /// Share ETA (NAV-15): one notice per trip.
    var friends: [Friend] = []
    var etaSent: Int?
    var etaFailed = false
    var sendingETA = false
    /// The meet at this destination that you're Going to, if any. Navigating marks you "on the way".
    @ObservationIgnored private var meet: MeetID?
    @ObservationIgnored private var monitor = NWPathMonitor()
    @ObservationIgnored private var convoyTask: Task<Void, Never>?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var hazardAlong: [ReportID: Double] = [:]
    @ObservationIgnored private var points: [CLLocationCoordinate2D] = []
    @ObservationIgnored private var cumulative: [Double] = []
    @ObservationIgnored private var stepEnds: [Double] = []
    @ObservationIgnored private var spoken: Set<String> = []
    @ObservationIgnored private var offSince: Date?
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let voice = AVSpeechSynthesizer()
    var muted: Bool {
        get { UserDefaults.standard.bool(forKey: "nav.muted") }
        set { UserDefaults.standard.set(newValue, forKey: "nav.muted") }
    }

    init(env: AppEnvironment, destination: Coordinate, name: String?) {
        self.env = env; self.destination = destination; self.name = name
    }

    var car: Car? { cars.isEmpty ? nil : cars[carIndex % cars.count] }
    var clearance: Clearance { car?.clearance ?? .stock }
    var current: ScoredRoute? { routes.indices.contains(selected) ? routes[selected] : nil }

    func load() async {
        watch()
        if let me = await env.auth.currentSession()?.userID {
            cars = (try? await env.garage.cars(of: me)) ?? []
            meet = await goingMeet(me)
        }
        calculate(from: nil)
        friends = ((try? await env.friends.friends()) ?? []).sorted { $0.profile.displayName < $1.profile.displayName }
    }

    /// A meet you're Going to whose spot is this destination (within 150 m) and has not ended.
    private func goingMeet(_ me: UserID) async -> MeetID? {
        let near = ((try? await env.meets.upcomingMeets(for: me)) ?? [])
            .filter { $0.cancelledAt == nil && $0.endsAt > .now && $0.coordinate.distance(to: destination) <= 150 }
        for m in near {
            if let r = try? await env.meets.myRSVP(for: m.id), r.status == .going { return m.id }
        }
        return nil
    }

    /// Arrival from the loaded route, scaled by what is left of it.
    var arrival: Date {
        guard let r = current?.route else { return .now }
        let left = remaining > 0 ? r.expectedTravelTime * (remaining / max(r.distance, 1)) : r.expectedTravelTime
        return Date.now.addingTimeInterval(left)
    }

    /// Sends the chosen friends one notice: destination name and arrival time, no position.
    func shareETA(with users: [UserID]) async {
        guard !users.isEmpty, etaSent == nil else { return }
        sendingETA = true
        defer { sendingETA = false }
        do {
            let result = try await env.gateway.shareETA(ETAShare(recipients: users, destination: destinationName,
                                                                 arriveAt: arrival, meet: meet))
            etaSent = result.sent
            etaFailed = false
        } catch {
            etaFailed = true
        }
    }

    /// Marks your Going RSVP "on the way" when guidance starts toward the meet.
    private func markOnTheWay() {
        guard let meet else { return }
        let share = ETAShare(recipients: [], destination: destinationName, arriveAt: arrival, meet: meet)
        let gateway = env.gateway
        Task { _ = try? await gateway.shareETA(share) }
    }

    var destinationName: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Destination", bundle: .module) }

    /// Starts the reachability monitor and follows convoy membership. Core's
    /// `RealtimeService.activeConvoy()` keeps the convoy id current.
    private func watch() {
        guard !watching else { return }
        watching = true
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor [weak self] in self?.online = ok }
        }
        monitor.start(queue: .global(qos: .utility))
        let env = self.env
        convoyTask = Task { [weak self] in
            for await active in await env.realtime.activeConvoy() { self?.convoyID = active?.id }
        }
    }

    func teardown() {
        convoyTask?.cancel()
        monitor.cancel()
        watching = false
    }

    /// Sets this destination for the whole convoy (`PUT /v1/convoys/{id}/destination`).
    func shareWithConvoy() async {
        guard let id = convoyID else { return }
        do {
            try await env.gateway.setConvoyDestination(id, ConvoyDestination(coordinate: destination, name: name ?? String(localized: "Destination", bundle: .module)))
            sharedWithConvoy = true
            shareFailed = false
        } catch {
            shareFailed = true
        }
    }

    func calculate(from origin: CLLocationCoordinate2D?) {
        loading = true
        let request = MKDirections.Request()
        request.source = origin.map { MKMapItem(placemark: MKPlacemark(coordinate: $0)) } ?? .forCurrentLocation()
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.cl))
        request.transportType = .automobile
        request.requestsAlternateRoutes = origin == nil
        MKDirections(request: request).calculate { response, _ in
            MainActor.assumeIsolated { self.received(response?.routes ?? []) }
        }
    }

    private func received(_ found: [MKRoute]) {
        loading = false
        rerouting = false
        offSince = nil
        guard !found.isEmpty else { error = true; return }
        error = false
        routes = found.prefix(3).map { ScoredRoute(route: $0) }
        selected = bestIndex()
        if guiding, let r = current { prepare(r.route) }
        let paths = routes.map { Self.sample($0.route.polyline, every: 20) }
        Task { await score(paths) }
    }

    private func score(_ paths: [[Coordinate]]) async {
        for (i, path) in paths.enumerated() where routes.indices.contains(i) {
            routes[i].hazards = (try? await env.reports.hazards(along: path, bufferMeters: 25)) ?? []
        }
        if guiding { indexHazards() } else { selected = bestIndex() }
    }

    /// Places each clearance hazard on the loaded route as metres from its start, so the strip
    /// only fires for reports ahead on the route, not ones beside it or behind.
    private func indexHazards() {
        hazardAlong = [:]
        guard let r = current, !points.isEmpty else { return }
        for h in r.clearanceHazards(for: clearance) {
            let loc = CLLocation(latitude: h.coordinate.latitude, longitude: h.coordinate.longitude)
            var best = (dist: Double.greatestFiniteMagnitude, along: 0.0)
            for i in points.indices {
                let d = loc.distance(from: CLLocation(latitude: points[i].latitude, longitude: points[i].longitude))
                if d < best.dist { best = (d, cumulative[i]) }
            }
            if best.dist <= 40 { hazardAlong[h.id] = best.along }
        }
    }

    /// Fewest clearance hazards among routes within 20% of the fastest.
    func bestIndex() -> Int {
        guard let fastest = routes.map(\.route.expectedTravelTime).min() else { return 0 }
        let candidates = routes.indices.filter { routes[$0].route.expectedTravelTime <= fastest * 1.2 }
        return candidates.min { routes[$0].clearanceHazards(for: clearance).count < routes[$1].clearanceHazards(for: clearance).count } ?? 0
    }

    func cycleCar() {
        guard !cars.isEmpty else { return }
        carIndex = (carIndex + 1) % cars.count
        selected = bestIndex()
    }

    static func sample(_ line: MKPolyline, every: Int) -> [Coordinate] {
        let pts = line.points()
        return stride(from: 0, to: line.pointCount, by: max(1, line.pointCount / 200)).map {
            let c = pts[$0].coordinate
            return Coordinate(latitude: c.latitude, longitude: c.longitude)
        }
    }

    // MARK: Guidance

    func start() {
        guard let r = current else { return }
        guiding = true
        prepare(r.route)
        markOnTheWay()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        task = Task { [weak self] in
            guard let self else { return }
            for await sample in await self.env.location.samples() { self.update(sample) }
        }
    }

    func stop() {
        task?.cancel()
        guiding = false
        voice.stopSpeaking(at: .immediate)
    }

    private func prepare(_ route: MKRoute) {
        let line = route.polyline
        let pts = line.points()
        points = (0..<line.pointCount).map { pts[$0].coordinate }
        cumulative = [0]
        for i in 1..<max(points.count, 1) {
            cumulative.append(cumulative[i - 1] + CLLocation(latitude: points[i - 1].latitude, longitude: points[i - 1].longitude)
                .distance(from: CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)))
        }
        var total = 0.0
        stepEnds = route.steps.map { total += $0.distance; return total }
        stepIndex = 0
        spoken = []
        indexHazards()
    }

    private func update(_ s: LocationSample) {
        let here = s.coordinate.cl
        me = here
        speed = max(0, s.speed)
        if let h = s.heading { heading = h }
        guard let r = current, !points.isEmpty else { return }
        // Snap to the polyline.
        var best = (dist: Double.greatestFiniteMagnitude, along: 0.0)
        let loc = CLLocation(latitude: here.latitude, longitude: here.longitude)
        for i in points.indices {
            let d = loc.distance(from: CLLocation(latitude: points[i].latitude, longitude: points[i].longitude))
            if d < best.dist { best = (d, cumulative[i]) }
        }
        let total = cumulative.last ?? 0
        remaining = max(0, total - best.along)
        stepIndex = stepEnds.firstIndex { $0 > best.along + 5 } ?? max(0, r.route.steps.count - 1)
        toManeuver = max(0, (stepEnds.indices.contains(stepIndex) ? stepEnds[stepIndex] : total) - best.along)

        // Off route: > 40 m for 5 s; at most one request every 8 s. Offline, keep the loaded route.
        if best.dist > 40 {
            offRoute = true
            offSince = offSince ?? .now
            if online, let since = offSince, Date.now.timeIntervalSince(since) > 5, Date.now.timeIntervalSince(lastReroute) > 8 {
                lastReroute = .now
                rerouting = true
                calculate(from: here)
            }
        } else {
            offRoute = false
            offSince = nil
        }

        if remaining < 30 && !arrived {
            arrived = true
            say("You've arrived", key: "arrive")
            Task { try? await Task.sleep(for: .seconds(10)); stop() }
        }

        // Voice at 800 m, 200 m, and the maneuver.
        let steps = r.route.steps
        if steps.indices.contains(stepIndex + 1) || steps.indices.contains(stepIndex) {
            let next = steps.indices.contains(stepIndex + 1) ? steps[stepIndex + 1] : steps[stepIndex]
            let text = next.instructions
            if !text.isEmpty {
                for mark in [800.0, 200.0, 25.0] where toManeuver <= mark {
                    let key = "\(stepIndex)-\(Int(mark))"
                    if !spoken.contains(key) {
                        spoken.insert(key)
                        if mark == 25 { say(text, key: key) } else { say("In \(Self.distance(mark, spoken: true)), \(text.prefix(1).lowercased() + text.dropFirst())", key: key) }
                        break
                    }
                }
            }
        }

        // Hazard ahead on the route within 250 m for a non-stock car: strip, one haptic, one spoken line.
        if clearance != .stock {
            let ahead = r.clearanceHazards(for: clearance)
                .compactMap { h -> (report: Report, meters: Double)? in
                    guard let at = hazardAlong[h.id] else { return nil }
                    let d = at - best.along
                    return d > 0 && d <= 250 ? (h, d) : nil
                }
                .min { $0.meters < $1.meters }
            if let ahead {
                hazardDistance = ahead.meters
                if hazardAhead?.id != ahead.report.id {
                    hazardAhead = ahead.report
                    let key = "h-\(ahead.report.id)"
                    if !spoken.contains(key) {
                        spoken.insert(key)
                        say("\(Self.kindName(ahead.report.kind)) in \(Self.distance(ahead.meters, spoken: true))", key: key)
                    }
                }
            } else {
                hazardAhead = nil
            }
        }
    }

    private func say(_ text: String, key: String) {
        guard !muted else { return }
        voice.speak(AVSpeechUtterance(string: text))
    }

    static func kindName(_ k: ReportKind) -> String {
        switch k {
        case .speedBump: "Speed bump"
        case .steepEntrance: "Steep entrance"
        case .pothole: "Pothole"
        case .roughRoad: "Rough road"
        default: "Hazard"
        }
    }

    /// Road distance in the device locale's units (SET-3): feet then miles, or metres then
    /// kilometres. Abbreviated on screen ("250 ft"), spelled out for voice ("250 feet").
    static func distance(_ meters: Double, spoken: Bool = false) -> String {
        let imperial = Locale.current.measurementSystem != .metric
        let value: Measurement<UnitLength>
        let digits: Int
        if imperial {
            let feet = Measurement(value: meters, unit: UnitLength.meters).converted(to: .feet).value
            if feet < 1000 {
                value = Measurement(value: (feet / 50).rounded() * 50, unit: .feet); digits = 0
            } else {
                value = Measurement(value: meters, unit: UnitLength.meters).converted(to: .miles); digits = 1
            }
        } else if meters < 1000 {
            value = Measurement(value: (meters / 10).rounded() * 10, unit: .meters); digits = 0
        } else {
            value = Measurement(value: meters, unit: UnitLength.meters).converted(to: .kilometers); digits = 1
        }
        return value.formatted(.measurement(width: spoken ? .wide : .abbreviated, usage: .asProvided,
                                            numberFormatStyle: .number.precision(.fractionLength(0...digits))))
    }

    /// Your own speed in the locale's road unit. Never anyone else's.
    var speedReadout: (value: String, unit: String) {
        let unit: UnitSpeed = Locale.current.measurementSystem == .metric ? .kilometersPerHour : .milesPerHour
        let v = Measurement(value: speed, unit: UnitSpeed.metersPerSecond).converted(to: unit).value
        return (v.formatted(.number.precision(.fractionLength(0))), unit.symbol)
    }
}

struct NavigationRoot: View {
    @State private var model: NavigationModel
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, destination: Coordinate, name: String?) {
        _model = State(initialValue: NavigationModel(env: env, destination: destination, name: name))
    }

    var body: some View {
        Group {
            if model.guiding { GuidanceView(model: model) { model.stop(); dismiss() } } else { RoutePreview(model: model) { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .onDisappear { model.teardown() }
    }
}

// MARK: M3 Route preview

struct RoutePreview: View {
    @Bindable var model: NavigationModel
    let close: () -> Void
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, r in
                    MapPolyline(r.route.polyline)
                        .stroke(i == model.selected ? Color.sodium : Color.dust,
                                lineWidth: i == model.selected ? Size.Route.selected : Size.Route.alternate)
                    ForEach(r.clearanceHazards(for: model.clearance)) { h in
                        Annotation("", coordinate: h.coordinate.cl) { ReportBadge(kind: h.kind.rawValue).scaleEffect(Size.Marker.routeHazardScale) }
                    }
                }
                Marker(model.name ?? "", coordinate: model.destination.cl).tint(Color.sodium)
            }
            .mapStyle(.standard(emphasis: .muted))
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                IconButton(Symbol.close, label: "Close", style: .overMap, action: close).padding(Space.margin)
            }
            sheet
        }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack {
                Text(verbatim: model.name ?? "Destination").typeStyle(.title).foregroundStyle(Color.chalk)
                Spacer()
                if let car = model.car {
                    Button { model.cycleCar() } label: {
                        CarBadge(car.shortLabel, paint: car.colorHex.flatMap { Color(paintHex: $0) } ?? .dust)
                    }
                }
            }
            if model.loading {
                SkeletonRow(); SkeletonRow()
            } else if model.error {
                ErrorState(Text("Couldn't find a route there.", bundle: .module)) { model.calculate(from: nil) }
            } else {
                let best = model.bestIndex()
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, r in
                    Button { model.selected = i } label: { row(r, best: i == best && model.clearance != .stock, selected: i == model.selected) }
                        .buttonStyle(RowButtonStyle())
                }
                if model.clearance != .stock, model.routes.allSatisfy({ !$0.clearanceHazards(for: model.clearance).isEmpty }) {
                    Text("No route avoids these. Apple Maps routing can't be steered around them.", bundle: .module)
                        .typeStyle(.foot).foregroundStyle(Color.dust)
                }
                PrimaryButton("Go") { model.start() }
                if model.convoyID != nil {
                    if model.sharedWithConvoy {
                        Text("Shared with your convoy.", bundle: .module).typeStyle(.sub).foregroundStyle(Color.go)
                    } else {
                        QuietButton("Share with convoy") { Task { await model.shareWithConvoy() } }
                    }
                    if model.shareFailed {
                        Text("Couldn't share the destination. Try again.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.brake)
                    }
                }
            }
        }
        .padding(Space.margin)
        .background(Color.tarmac, in: UnevenRoundedRectangle(topLeadingRadius: Radius.r28, topTrailingRadius: Radius.r28))
    }

    private func row(_ r: ScoredRoute, best: Bool, selected: Bool) -> some View {
        let hazards = r.clearanceHazards(for: model.clearance)
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack {
                Text(verbatim: "\(Int(r.route.expectedTravelTime / 60)) min").typeStyle(.readoutL)
                    .foregroundStyle(selected ? Color.sodium : Color.chalk)
                if best { Text("Best for your car", bundle: .module).typeStyle(.label).foregroundStyle(Color.go) }
            }
            Text(verbatim: "\(NavigationModel.distance(r.route.distance)) · \(r.route.name)").typeStyle(.sub).foregroundStyle(Color.dust)
            if model.clearance != .stock {
                if hazards.isEmpty {
                    Text("Clear for a lowered car", bundle: .module).typeStyle(.sub).foregroundStyle(Color.go)
                } else {
                    let counts = Dictionary(grouping: hazards, by: \.kind).map { "\($0.value.count) \(NavigationModel.kindName($0.key).lowercased())\($0.value.count > 1 ? "s" : "")" }
                    Text(verbatim: counts.joined(separator: ", ")).typeStyle(.sub).foregroundStyle(Color.sodium)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.s8)
    }
}

// MARK: M4 Guidance

struct GuidanceView: View {
    @Bindable var model: NavigationModel
    let end: () -> Void
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var sharingETA = false

    var body: some View {
        ZStack {
            Map(position: $position) {
                UserAnnotation()
                if let r = model.current { MapPolyline(r.route.polyline).stroke(Color.sodium, lineWidth: Size.Route.selected) }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .ignoresSafeArea()
            VStack(spacing: 0) {
                banner
                if let h = model.hazardAhead {
                    Text(verbatim: "\(NavigationModel.kindName(h.kind)) in \(NavigationModel.distance(model.hazardDistance))")
                        .typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                        .frame(maxWidth: .infinity).padding(Space.s8).background(Color.sodium)
                        .padding(.horizontal, Space.margin)
                }
                Spacer()
                HStack {
                    let readout = model.speedReadout
                    HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                        Text(verbatim: readout.value).typeStyle(.readoutXL).foregroundStyle(Color.chalk)
                        Text(verbatim: readout.unit).typeStyle(.foot).foregroundStyle(Color.dust)
                    }
                    .padding(.horizontal, Space.s16)
                    .background(Color.tarmac, in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, Space.margin)
                bottomBar
            }
        }
        .haptic(.warn, trigger: model.hazardAhead?.id) { _, new in new != nil }
        .sheet(isPresented: $sharingETA) { ShareETASheet(model: model).presentationDetents([.medium, .large]) }
    }

    private var banner: some View {
        let steps = model.current?.route.steps ?? []
        let next = steps.indices.contains(model.stepIndex + 1) ? steps[model.stepIndex + 1] : steps.last
        return HStack(spacing: Space.s12) {
            Image(systemName: arrow(next?.instructions ?? "")).font(TypeToken.readoutL.font).fontWeight(.bold)
                .foregroundStyle(Color.sodium).frame(width: Size.hitTarget)
            VStack(alignment: .leading, spacing: Space.s2) {
                if model.arrived {
                    Text("You've arrived", bundle: .module).typeStyle(.title).foregroundStyle(Color.chalk)
                    Text(verbatim: model.name ?? "").typeStyle(.bodyStrong).foregroundStyle(Color.dust)
                } else {
                    Text(verbatim: NavigationModel.distance(model.toManeuver)).typeStyle(.readoutL).foregroundStyle(Color.chalk)
                    Text(verbatim: model.offRoute && !model.online ? String(localized: "Offline. Follow the route line.", bundle: .module)
                         : model.rerouting ? String(localized: "Rerouting", bundle: .module) : (next?.instructions ?? "")).typeStyle(.bodyStrong)
                        .foregroundStyle(Color.chalk).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(Space.s16)
        .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r20))
        .padding(.horizontal, Space.margin)
    }

    private var bottomBar: some View {
        HStack(spacing: Space.s16) {
            let eta = model.arrival
            VStack(alignment: .leading) {
                Text(verbatim: eta.formatted(date: .omitted, time: .shortened)).typeStyle(.readoutM).foregroundStyle(Color.chalk)
                Text(verbatim: NavigationModel.distance(model.remaining)).typeStyle(.foot).foregroundStyle(Color.dust)
            }
            Spacer()
            if model.etaSent == nil && !model.friends.isEmpty && !model.arrived {
                IconButton(Symbol.share, label: "Share ETA") { sharingETA = true }
            }
            IconButton(model.muted ? "speaker.slash" : Symbol.speaker, label: model.muted ? "Unmute" : "Mute") { model.muted.toggle() }
            Button("End", action: end)
                .typeStyle(.bodyStrong).foregroundStyle(Color.brake)
                .frame(width: Size.wideButton, height: Size.control)
                .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12))
        }
        .padding(Space.margin)
        .background(Color.tarmac)
    }

    private func arrow(_ text: String) -> String {
        let t = text.lowercased()
        if t.contains("u-turn") { return "arrow.uturn.down" }
        if t.contains("slight left") || t.contains("keep left") { return "arrow.up.left" }
        if t.contains("slight right") || t.contains("keep right") { return "arrow.up.right" }
        if t.contains("left") { return "arrow.turn.up.left" }
        if t.contains("right") { return "arrow.turn.up.right" }
        if t.contains("arrive") || t.contains("destination") { return "mappin" }
        return "arrow.up"
    }
}

// MARK: Share ETA (NAV-15)

/// Pick friends; they get one notice with where you're headed and when you'll get there.
struct ShareETASheet: View {
    @Bindable var model: NavigationModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UserID> = []

    var body: some View {
        Sheet(Text("Share ETA", bundle: .module)) {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("They get one notice: \(model.destinationName), arriving \(model.arrival.formatted(date: .omitted, time: .shortened)). Not your location.", bundle: .module)
                    .typeStyle(.sub).foregroundStyle(Color.dust)
                ScrollView {
                    ForEach(model.friends) { f in
                        Button {
                            if chosen.contains(f.id) { chosen.remove(f.id) } else { chosen.insert(f.id) }
                        } label: {
                            Row(Text(verbatim: f.profile.displayName), leading: { Avatar(name: f.profile.displayName, size: .s28) },
                                trailing: {
                                    Image(systemName: chosen.contains(f.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(f.id) ? Color.sodium : Color.gravel)
                                })
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                if model.etaFailed {
                    Text("Couldn't send it. Try again.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.brake)
                }
                PrimaryButton("Send", isLoading: model.sendingETA) {
                    let users = Array(chosen)
                    Task {
                        await model.shareETA(with: users)
                        if model.etaSent != nil { dismiss() }
                    }
                }
                .disabled(chosen.isEmpty)
            }
        }
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
