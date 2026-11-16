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
        registry.registerRoute(.navigatePath, presentation: .fullScreen) { route in
            guard case let .navigatePath(path, name) = route, let end = path.last else { return nil }
            return AnyView(NavigationRoot(env: env, destination: end, name: name, path: path))
        }
        registry.registerDebugScreen("stops") { AnyView(StopsSheet(model: .stopsSeed(env)).background(Color.tarmac).preferredColorScheme(.dark)) }
        #if DEBUG
        registry.registerDebugScreen("nav-go") { AnyView(DebugNavGo(env: env)) }
        #endif
    }
}

#if DEBUG
/// `waypoints://debug/nav-go`: guidance without tapping Go (NAV-5/6/9 proof) — the first
/// upcoming meet like `debug/nav`, started once routes load.
private struct DebugNavGo: View {
    let env: AppEnvironment
    @State private var meet: Meet?
    var body: some View {
        NavigationRoot(env: env,
                       destination: meet?.coordinate ?? Coordinate(latitude: 39.9387, longitude: -75.0230),
                       name: meet?.placeName ?? "Cherry Hill Mall",
                       autoStart: true)
            .task {
                let region = MapRegion(minLatitude: 39.3, minLongitude: -75.4, maxLatitude: 40.2, maxLongitude: -74.4)
                meet = (try? await env.meets.meets(in: region))?.sorted { $0.startsAt < $1.startsAt }.first { $0.endsAt > .now }
            }
    }
}
#endif

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
    /// One target along a multi-leg path (a loop's joined roads), with its distance along it.
    private struct Leg {
        let at: CLLocationCoordinate2D
        let along: Double
    }

    let env: AppEnvironment
    let destination: Coordinate
    let name: String?
    /// A multi-leg path to follow end to end (ROAD-6); nil for a single destination.
    let path: [Coordinate]?
    /// The whole path as a line, drawn under the routed leg.
    let pathLine: [CLLocationCoordinate2D]?
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
    var stillThere: Report?
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
    var etaLimited = false
    var sendingETA = false
    /// Stop on the way (NAV-16): the chosen stop, and the candidates for the "Add a stop" sheet.
    var stop: Stop?
    var stops: [Stop] = []
    var stopKind = StopKind.fuel
    var stopsLoading = false
    var stopsError = false
    /// Reached the stop; waiting for the route on to the destination.
    @ObservationIgnored var continuing = false
    @ObservationIgnored var stopSearch = 0
    @ObservationIgnored var stopPending = 0
    @ObservationIgnored var stopFailed = false
    @ObservationIgnored var stopFound: [(name: String, at: CLLocationCoordinate2D, off: Double)] = []
    /// The meet at this destination that you're Going to, if any. Navigating marks you "on the way".
    @ObservationIgnored private var meet: MeetID?
    @ObservationIgnored private var monitor = NWPathMonitor()
    @ObservationIgnored private var convoyTask: Task<Void, Never>?
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var asked: Set<ReportID> = []
    @ObservationIgnored private var hazardAlong: [ReportID: Double] = [:]
    @ObservationIgnored private var points: [CLLocationCoordinate2D] = []
    /// Legs still to drive along `path`; `legs.first` is the current MKDirections target.
    @ObservationIgnored private var legs: [Leg] = []
    @ObservationIgnored private var pathLength = 0.0
    @ObservationIgnored private var cumulative: [Double] = []
    @ObservationIgnored private var stepEnds: [Double] = []
    @ObservationIgnored private var spoken: Set<String> = []
    @ObservationIgnored private var offSince: Date?
    @ObservationIgnored private var lastReroute = Date.distantPast
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let voice = AVSpeechSynthesizer()
    var muted = UserDefaults.standard.bool(forKey: "nav.muted") {
        didSet {
            UserDefaults.standard.set(muted, forKey: "nav.muted")
            if muted { voice.stopSpeaking(at: .immediate) }
        }
    }

    init(env: AppEnvironment, destination: Coordinate, name: String?, path: [Coordinate]? = nil) {
        self.env = env; self.destination = destination; self.name = name; self.path = path
        self.pathLine = path?.map(\.cl)
        if let path, path.count > 1 { (legs, pathLength) = Self.legs(along: path) }
    }

    /// Waypoints along `path` to route through in turn: the start, points about 400 m apart
    /// (at most ~40 legs however long the path), and the end. Each leg gets real turn-by-turn
    /// from MKDirections; the driver is steered leg to leg along the saved roads.
    private static func legs(along path: [Coordinate]) -> ([Leg], Double) {
        var cum = [0.0]
        for i in 1..<path.count { cum.append(cum[i - 1] + path[i - 1].distance(to: path[i])) }
        let total = cum.last ?? 0
        guard total > 0 else { return ([], 0) }   // a zero-length path navigates as one destination
        let spacing = max(400, total / 40)
        var legs = [Leg(at: path[0].cl, along: 0)]
        var i = 1
        var next = spacing
        while next < total {
            while i < path.count - 1 && cum[i] < next { i += 1 }
            legs.append(Leg(at: path[i].cl, along: cum[i]))
            next += spacing
        }
        if (legs.last?.along ?? -1) < total { legs.append(Leg(at: path[path.count - 1].cl, along: total)) }
        return (legs, total)
    }

    /// Fraction of a multi-leg path covered, for the guidance readout. Nil for one destination.
    var pathProgress: Double? {
        guard path != nil else { return nil }
        guard let leg = legs.first else { return pathLength > 0 ? 1 : nil }
        return min(1, max(0, (leg.along - remaining) / max(pathLength, 1)))
    }

    var car: Car? { cars.isEmpty ? nil : cars[carIndex % cars.count] }
    var clearance: Clearance { car?.clearance ?? .stock }
    var current: ScoredRoute? { routes.indices.contains(selected) ? routes[selected] : nil }

    func load() async {
        watch()
        guard !loaded else { return }
        loaded = true
        if let me = await env.auth.currentSession()?.userID {
            cars = (try? await env.garage.cars(of: me)) ?? []
            meet = await goingMeet(me)
        }
        // STORE-2: route from the first location sample when one lands quickly. A nil
        // origin makes MKDirections use the device fix, which a fresh simulator may
        // never send — the sheet then shows skeletons forever, no ETAs and no Go.
        calculate(from: await firstFix(), alternates: true)
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

    /// Metres left of the whole trip in path mode: the current leg's remainder plus every leg
    /// still to drive. `remaining` alone is only the current leg's (~400 m), which would make
    /// the readout and ETA jump at each leg.
    var tripRemaining: Double {
        guard path != nil, pathLength > 0, let leg = legs.first else { return remaining }
        return max(0, pathLength - leg.along + remaining)
    }

    /// Arrival at the destination from the loaded route, scaled by what is left of it, plus the
    /// leg after the stop when there is one.
    var arrival: Date {
        guard let r = current?.route else { return .now }
        if path != nil {
            // Legs are routed one at a time; assume the current leg's pace for the whole path.
            let pace = r.distance > 0 ? r.expectedTravelTime / r.distance : 0
            return Date.now.addingTimeInterval(tripRemaining * pace + (stop?.onward?.expectedTravelTime ?? 0))
        }
        let left = remaining > 0 ? r.expectedTravelTime * (remaining / max(r.distance, 1)) : r.expectedTravelTime
        return Date.now.addingTimeInterval(left + (stop?.onward?.expectedTravelTime ?? 0))
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
            etaLimited = (error as? WaypointsError) == .rateLimited
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

    /// First location sample, waiting up to 3 s (the preview seed answers at once).
    private func firstFix() async -> CLLocationCoordinate2D? {
        let env = self.env
        return await withTaskGroup(of: CLLocationCoordinate2D?.self) { group in
            group.addTask {
                for await sample in await env.location.samples() { return sample.coordinate.cl }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    func calculate(from origin: CLLocationCoordinate2D?, alternates: Bool = false) {
        loading = true
        // A stop wins; otherwise the next leg along a multi-leg path, else the destination.
        let request = Self.request(from: origin, to: stop?.coordinate ?? legs.first?.at ?? destination.cl)
        request.requestsAlternateRoutes = alternates
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
        continuing = false
        routes = found.prefix(3).map { ScoredRoute(route: $0) }
        selected = bestIndex()
        if guiding, let r = current { prepare(r.route) }
        let paths = routes.map { Self.sample($0.route.polyline, every: 20) }
        Task { await score(paths) }
    }

    private func score(_ paths: [[Coordinate]]) async {
        let ids = routes.map(\.id)
        for (i, path) in paths.enumerated() {
            let found = (try? await env.reports.hazards(along: path, bufferMeters: 25)) ?? []
            guard routes.map(\.id) == ids else { return }
            routes[i].hazards = found
        }
        if guiding { indexHazards() } else { selected = bestIndex() }
    }

    /// Places each clearance hazard on the loaded route as metres from its start, so the strip
    /// only fires for reports ahead on the route, not ones beside it or behind.
    private func indexHazards() {
        hazardAlong = [:]
        guard let r = current, !points.isEmpty else { return }
        for h in r.clearanceHazards(for: clearance) {
            let best = snap(h.coordinate.cl)
            if best.dist <= 40 { hazardAlong[h.id] = best.along }
        }
    }

    private func snap(_ c: CLLocationCoordinate2D) -> (dist: Double, along: Double) {
        guard let first = points.first, cumulative.count == points.count else { return (.greatestFiniteMagnitude, 0) }
        let kx = 111_320 * cos(c.latitude * .pi / 180), ky = 110_540.0
        var best = (dist: hypot((first.longitude - c.longitude) * kx, (first.latitude - c.latitude) * ky), along: 0.0)
        for i in points.indices.dropLast() {
            let ax = (points[i].longitude - c.longitude) * kx, ay = (points[i].latitude - c.latitude) * ky
            let dx = (points[i + 1].longitude - points[i].longitude) * kx, dy = (points[i + 1].latitude - points[i].latitude) * ky
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(ax * dx + ay * dy) / len2)) : 0
            let d = hypot(ax + t * dx, ay + t * dy)
            if d < best.dist { best = (d, cumulative[i] + t * (cumulative[i + 1] - cumulative[i])) }
        }
        return best
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
        Task { await env.location.setActive(.navigation, true) }
        prepare(r.route)
        markOnTheWay()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        task = Task { [weak self] in
            guard let self else { return }
            for await sample in await self.env.location.samples() { self.update(sample) }
        }
    }

    func endGuidance() {
        task?.cancel()
        guiding = false
        Task { await env.location.setActive(.navigation, false) }
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
        let best = snap(here)
        let total = cumulative.last ?? 0
        remaining = max(0, total - best.along)
        stepIndex = stepEnds.firstIndex { $0 > best.along + 5 } ?? max(0, r.route.steps.count - 1)
        toManeuver = max(0, (stepEnds.indices.contains(stepIndex) ? stepEnds[stepIndex] : total) - best.along)

        // Off route: > 40 m for 5 s; at most one request every 8 s. Offline, keep the loaded route.
        if best.dist > 40 {
            offRoute = true
            offSince = offSince ?? .now
            if online, !rerouting, !arrived, let since = offSince, Date.now.timeIntervalSince(since) > 5, Date.now.timeIntervalSince(lastReroute) > 8 {
                lastReroute = .now
                rerouting = true
                calculate(from: here)
            }
        } else {
            offRoute = false
            offSince = nil
        }

        if remaining < 30 && !arrived && !loading && !continuing {
            if stop != nil {
                // At the stop: carry on to the destination. If that route fails, the off-route check
                // asks again once you drive away.
                stop = nil
                continuing = true
                calculate(from: here)
            } else if !legs.isEmpty {
                // Reached this leg's target: route on to the next one along the path.
                legs.removeFirst()
                continuing = true
                calculate(from: here)
            } else {
                arrived = true
                say(String(localized: "You've arrived", bundle: .module), key: "arrive")
            }
        }

        // Voice at 800 m, 200 m, and the maneuver, in our own phrases (NAV-6).
        let steps = r.route.steps
        if !arrived, steps.indices.contains(stepIndex + 1),
           let mark = [25.0, 200.0, 800.0].first(where: { toManeuver <= $0 }) {
            let key = "\(stepIndex)-\(Int(mark))"
            if !spoken.contains(key) {
                for m in [800.0, 200.0, 25.0] where m >= mark { spoken.insert("\(stepIndex)-\(Int(m))") }
                let phrase = Self.phrase(from: steps[stepIndex], into: steps[stepIndex + 1],
                                         arrival: stepIndex + 1 == steps.count - 1)
                if mark == 25 {
                    // The last step is the arrival itself; the "You've arrived" line covers it.
                    if stepIndex + 1 < steps.count - 1 {
                        say(phrase.prefix(1).uppercased() + phrase.dropFirst(), key: key)
                    }
                } else {
                    say(String(localized: "In \(Self.distance(toManeuver, spoken: true)), \(phrase)", bundle: .module), key: key)
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
                        say(String(localized: "\(Self.kindName(ahead.report.kind)) in \(Self.distance(ahead.meters, spoken: true))", bundle: .module), key: key)
                    }
                }
            } else {
                hazardAhead = nil
            }
        }

        if stillThere == nil, !arrived,
           let p = r.hazards.first(where: { [ReportKind.police, .hazard, .closure].contains($0.kind) && !asked.contains($0.id)
               && $0.coordinate.distance(to: s.coordinate) <= 40 }) {
            asked.insert(p.id)
            stillThere = p
            Task { try? await Task.sleep(for: .seconds(8)); if stillThere?.id == p.id { stillThere = nil } }
        }
    }

    func answerStillThere(_ yes: Bool) {
        guard let p = stillThere else { return }
        stillThere = nil
        let gateway = env.gateway
        Task { try? await gateway.voteReport(p.id, stillThere: yes) }
    }

    private func say(_ text: String, key: String) {
        guard !muted else { return }
        voice.speak(AVSpeechUtterance(string: text))
    }

    /// The maneuver into `next`, phrased by our own template (NAV-6). MapKit exposes no
    /// structured maneuver type, so the turn is read from the geometry — the heading at the
    /// end of `current` against the heading at the start of `next` — and the only display
    /// text kept is `next`'s road clause ("onto Main Street"); where MapKit phrases it
    /// differently the prompt just omits the road.
    private static func phrase(from current: MKRoute.Step, into next: MKRoute.Step, arrival: Bool) -> String {
        if arrival { return String(localized: "arrive at your destination", bundle: .module) }
        let turn = (heading(of: next.polyline, atEnd: false) - heading(of: current.polyline, atEnd: true) + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        let verb: String
        switch turn {
        case ..<(-150): verb = String(localized: "make a U-turn", bundle: .module)
        case ..<(-50): verb = String(localized: "turn left", bundle: .module)
        case ..<(-20): verb = String(localized: "bear left", bundle: .module)
        case ..<20: verb = String(localized: "continue", bundle: .module)
        case ..<50: verb = String(localized: "bear right", bundle: .module)
        case ..<150: verb = String(localized: "turn right", bundle: .module)
        default: verb = String(localized: "make a U-turn", bundle: .module)
        }
        for connector in [" onto ", " toward "] {
            if let clause = next.instructions.range(of: connector, options: .caseInsensitive) {
                return "\(verb) \(next.instructions[clause.lowerBound...].trimmingCharacters(in: .whitespaces))"
            }
        }
        return verb
    }

    /// Compass heading (°) along the first (or last) ~25 m of a step's polyline.
    private static func heading(of line: MKPolyline, atEnd end: Bool) -> Double {
        let pts = line.points()
        var coords = (0..<line.pointCount).map { pts[$0].coordinate }
        if end { coords.reverse() }
        guard coords.count >= 2 else { return 0 }
        var far = coords[1]
        var walked = 0.0
        for i in 1..<coords.count {
            walked += CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
            far = coords[i]
            if walked >= 25 { break }
        }
        let dLon = (far.longitude - coords[0].longitude) * .pi / 180
        let la1 = coords[0].latitude * .pi / 180, la2 = far.latitude * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    static func kindName(_ k: ReportKind) -> String {
        switch k {
        case .speedBump: String(localized: "Speed bump", bundle: .module)
        case .steepEntrance: String(localized: "Steep entrance", bundle: .module)
        case .pothole: String(localized: "Pothole", bundle: .module)
        case .roughRoad: String(localized: "Rough road", bundle: .module)
        case .police: String(localized: "Police", bundle: .module)
        case .closure: String(localized: "Closure", bundle: .module)
        default: String(localized: "Hazard", bundle: .module)
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
                let miles = Measurement(value: meters, unit: UnitLength.meters).converted(to: .miles).value
                if spoken, miles < 1 {
                    // Voice says fractions ("half a mile"), not "0.5 miles".
                    switch Int((miles * 4).rounded()) {
                    case 1: return String(localized: "a quarter of a mile", bundle: .module)
                    case 2: return String(localized: "half a mile", bundle: .module)
                    case 3: return String(localized: "three quarters of a mile", bundle: .module)
                    default: return String(localized: "a mile", bundle: .module)
                    }
                }
                value = Measurement(value: miles, unit: .miles); digits = 1
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
    let autoStart: Bool
    @Environment(\.dismiss) private var dismiss

    init(env: AppEnvironment, destination: Coordinate, name: String?, path: [Coordinate]? = nil, autoStart: Bool = false) {
        _model = State(initialValue: NavigationModel(env: env, destination: destination, name: name, path: path))
        self.autoStart = autoStart
    }

    var body: some View {
        Group {
            if model.guiding { GuidanceView(model: model) { model.endGuidance(); dismiss() } } else { RoutePreview(model: model) { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .task {
            await model.load()
            // `load` kicks off the route request; wait for the alternates (or failure) before
            // auto-starting for `waypoints://debug/nav-go`.
            if autoStart {
                for _ in 0..<50 where model.routes.isEmpty && !model.error {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                if !model.routes.isEmpty { model.start() }
            }
        }
        .onDisappear {
            model.endGuidance()
            model.teardown()
        }
    }
}

// MARK: M3 Route preview

struct RoutePreview: View {
    @Bindable var model: NavigationModel
    let close: () -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var addingStop = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $position) {
                UserAnnotation()
                if let line = model.pathLine {
                    MapPolyline(coordinates: line).stroke(Color.dust, lineWidth: Size.Route.alternate)
                }
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, r in
                    MapPolyline(r.route.polyline)
                        .stroke(i == model.selected ? Color.sodium : Color.dust,
                                lineWidth: i == model.selected ? Size.Route.selected : Size.Route.alternate)
                    ForEach(r.clearanceHazards(for: model.clearance)) { h in
                        Annotation("", coordinate: h.coordinate.cl) { ReportBadge(kind: h.kind.rawValue).scaleEffect(Size.Marker.routeHazardScale) }
                    }
                }
                Marker(model.name ?? "", coordinate: model.destination.cl).tint(Color.sodium)
                if let stop = model.stop {
                    if let onward = stop.onward { MapPolyline(onward.polyline).stroke(Color.sodium, lineWidth: Size.Route.selected) }
                    Marker(stop.name, coordinate: stop.coordinate).tint(Color.sodium)
                }
            }
            .mapStyle(.standard(emphasis: .muted))
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                IconButton(Symbol.close, label: "Close", style: .overMap, action: close).padding(Space.margin)
            }
            sheet
        }
        .sheet(isPresented: $addingStop) { StopsSheet(model: model).presentationDetents([.medium, .large]) }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            HStack {
                Text(verbatim: model.destinationName).typeStyle(.title).foregroundStyle(Color.chalk)
                Spacer()
                if let car = model.car {
                    Button { model.cycleCar() } label: {
                        CarBadge(car.shortLabel, paint: car.colorHex.flatMap { Color(paintHex: $0) } ?? .dust)
                            .frame(minHeight: Size.hitTarget).contentShape(Rectangle())
                    }
                    .accessibilityHint(Text("Switches to your next car", bundle: .module))
                }
            }
            if let stop = model.stop {
                HStack {
                    Text("Via \(stop.name)", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
                    Spacer()
                    QuietButton("Remove stop") { model.removeStop() }
                }
            }
            if model.loading {
                SkeletonRow(); SkeletonRow()
            } else if model.error {
                ErrorState(Text("Couldn't find a route there.", bundle: .module)) { model.calculate(from: nil) }
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let best = model.bestIndex()
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, r in
                    Button { model.selected = i } label: { row(r, best: i == best && model.clearance != .stock, selected: i == model.selected) }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityAddTraits(i == model.selected ? .isSelected : [])
                }
                if model.clearance != .stock, model.routes.allSatisfy({ !$0.clearanceHazards(for: model.clearance).isEmpty }) {
                    Text("No route avoids these. Apple Maps routing can't be steered around them.", bundle: .module)
                        .typeStyle(.foot).foregroundStyle(Color.dust)
                }
                PrimaryButton("Go") { model.start() }
                if model.stop == nil {
                    QuietButton("Add a stop") { model.findStops(model.stopKind); addingStop = true }
                }
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
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Radius.r28, topTrailingRadius: Radius.r28)
                .fill(Color.tarmac).ignoresSafeArea(edges: .bottom)
        }
    }

    private func row(_ r: ScoredRoute, best: Bool, selected: Bool) -> some View {
        let hazards = r.clearanceHazards(for: model.clearance)
        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s8) {
                Text(verbatim: "\(Int((r.route.expectedTravelTime + (model.stop?.onward?.expectedTravelTime ?? 0)) / 60))").font(TypeToken.readoutL.font)
                    .foregroundStyle(selected ? Color.sodium : Color.chalk)
                    + Text(verbatim: thinSpace + String(localized: "min", bundle: .module)).font(TypeToken.readoutS.font)
                    .foregroundStyle(Color.dust)
                if best { Text("Best for your car", bundle: .module).typeStyle(.label).foregroundStyle(Color.go) }
                Spacer(minLength: 0)
                if selected { Image.symbol(Symbol.confirm).foregroundStyle(Color.sodium).accessibilityHidden(true) }
            }
            Text(verbatim: "\(NavigationModel.distance(r.route.distance + (model.stop?.onward?.distance ?? 0))) · \(r.route.name)").typeStyle(.sub).foregroundStyle(Color.dust)
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
    @State private var addingStop = false

    var body: some View {
        ZStack {
            Map(position: $position) {
                UserAnnotation()
                if let line = model.pathLine {
                    MapPolyline(coordinates: line).stroke(Color.dust, lineWidth: Size.Route.alternate)
                }
                if let r = model.current { MapPolyline(r.route.polyline).stroke(Color.sodium, lineWidth: Size.Route.selected) }
                if let stop = model.stop {
                    if let onward = stop.onward { MapPolyline(onward.polyline).stroke(Color.dust, lineWidth: Size.Route.alternate) }
                    Marker(stop.name, coordinate: stop.coordinate).tint(Color.sodium)
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .ignoresSafeArea()
            VStack(spacing: 0) {
                banner.padding(.top, Space.s8)
                if let h = model.hazardAhead {
                    Text(verbatim: "\(NavigationModel.kindName(h.kind)) in \(NavigationModel.distance(model.hazardDistance))")
                        .typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                        .frame(maxWidth: .infinity).padding(Space.s8)
                        .background(Color.sodium, in: RoundedRectangle(cornerRadius: Radius.r12))
                        .padding(.horizontal, Space.margin)
                        .padding(.top, Space.s8)
                }
                if let p = model.stillThere {
                    HStack(spacing: Space.s8) {
                        Text(verbatim: NavigationModel.kindName(p.kind)).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                        Text("Still there?", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                        Spacer()
                        QuietButton("Still there") { model.answerStillThere(true) }
                        QuietButton("Gone") { model.answerStillThere(false) }
                    }
                    .padding(.horizontal, Space.s16)
                    .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r12))
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.s8)
                }
                Spacer()
                HStack {
                    let readout = model.speedReadout
                    HStack(alignment: .firstTextBaseline, spacing: Space.s4) {
                        Text(readout: readout.value, token: .readoutXL).foregroundStyle(Color.chalk)
                        Text(verbatim: readout.unit).typeStyle(.readoutS).foregroundStyle(Color.dust)
                    }
                    .padding(.horizontal, Space.s16)
                    .background(Color.tarmac, in: Capsule())
                    .mapShadow()
                    .accessibilityElement(children: .combine)
                    Spacer()
                    if !model.arrived {
                        QuietButton(model.stop == nil ? "Add a stop" : "Remove stop") {
                            if model.stop == nil { model.findStops(model.stopKind); addingStop = true } else { model.removeStop() }
                        }
                        .padding(.horizontal, Space.s16)
                        .background(Color.tarmac, in: Capsule())
                        .mapShadow()
                    }
                }
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.s12)
                bottomBar
            }
            // Glanceable while driving: the banner and bottom bar must stay compact, so text
            // scaling stops at the third accessibility size instead of covering the map.
            .dynamicTypeSize(.xSmall ... .accessibility3)
        }
        .haptic(.warn, trigger: model.hazardAhead?.id) { _, new in new != nil }
        .task(id: model.arrived) {
            guard model.arrived else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { end() }
        }
        .sheet(isPresented: $sharingETA) { ShareETASheet(model: model).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $addingStop) { StopsSheet(model: model).presentationDetents([.medium, .large]) }
    }

    private var banner: some View {
        let steps = model.current?.route.steps ?? []
        let next = steps.indices.contains(model.stepIndex + 1) ? steps[model.stepIndex + 1] : steps.last
        // The maneuver after next, when it follows within 300 m of the next (NAV-5).
        let following = steps.indices.contains(model.stepIndex + 2) && steps[model.stepIndex + 1].distance <= 300
            ? steps[model.stepIndex + 2] : nil
        return HStack(spacing: Space.s12) {
            Image(systemName: arrow(next?.instructions ?? "")).font(TypeToken.readoutL.font).fontWeight(.bold)
                .foregroundStyle(Color.sodium).frame(width: Size.hitTarget).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                if model.arrived {
                    Text("You've arrived", bundle: .module).typeStyle(.title).foregroundStyle(Color.chalk)
                    Text(verbatim: model.name ?? "").typeStyle(.bodyStrong).foregroundStyle(Color.dust)
                } else {
                    Text(verbatim: NavigationModel.distance(model.toManeuver)).typeStyle(.readoutL).foregroundStyle(Color.chalk)
                    Text(verbatim: model.offRoute && !model.online ? String(localized: "Offline. Follow the route line.", bundle: .module)
                         : model.rerouting ? String(localized: "Rerouting", bundle: .module) : (next?.instructions ?? "")).typeStyle(.bodyStrong)
                        .foregroundStyle(Color.chalk).fixedSize(horizontal: false, vertical: true)
                    if let following {
                        HStack(spacing: Space.s8) {
                            Image(systemName: arrow(following.instructions)).font(TypeToken.sub.font)
                                .foregroundStyle(Color.dust).accessibilityHidden(true)
                            Text(verbatim: following.instructions).typeStyle(.sub).foregroundStyle(Color.dust).lineLimit(1)
                        }
                    }
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
            VStack(alignment: .leading, spacing: Space.s2) {
                (Text(verbatim: eta.formatted(date: .omitted, time: .shortened) + " · \(max(0, Int(eta.timeIntervalSinceNow / 60)))")
                    .font(TypeToken.readoutM.font).foregroundStyle(Color.chalk)
                    + Text(verbatim: thinSpace + String(localized: "min", bundle: .module)).font(TypeToken.readoutS.font)
                    .foregroundStyle(Color.dust))
                    .contentTransition(.numericText())
                Text(verbatim: model.stop.map { String(localized: "\(NavigationModel.distance(model.remaining)) to \($0.name)", bundle: .module) }
                     ?? NavigationModel.distance(model.tripRemaining)).typeStyle(.foot).foregroundStyle(Color.dust)
                if let p = model.pathProgress {
                    Text(verbatim: "\(model.destinationName) · \(Int((p * 100).rounded()))%")
                        .typeStyle(.foot).foregroundStyle(Color.dust)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if model.etaSent == nil && !model.friends.isEmpty && !model.arrived && model.speed <= 8 / 3.6 {
                IconButton(Symbol.share, label: "Share ETA") { sharingETA = true }
            }
            IconButton(model.muted ? "speaker.slash" : Symbol.speaker, label: model.muted ? "Unmute" : "Mute") { model.muted.toggle() }
            Button(action: end) {
                Text("End", bundle: .module)
                    .typeStyle(.bodyStrong).foregroundStyle(Color.brake)
                    .frame(width: Size.wideButton, height: Size.control)
                    .background(Color.concrete, in: RoundedRectangle(cornerRadius: Radius.r12))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.r12))
            }
            .buttonStyle(PressScaleStyle())
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
                    .padding(.horizontal, Space.margin)
                ScrollView {
                    ForEach(model.friends) { f in
                        Button {
                            if chosen.contains(f.id) { chosen.remove(f.id) } else { chosen.insert(f.id) }
                        } label: {
                            Row(Text(verbatim: f.profile.displayName), leading: { Avatar(name: f.profile.displayName, size: .s28) },
                                trailing: {
                                    Image(systemName: chosen.contains(f.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(chosen.contains(f.id) ? Color.sodium : Color.gravel)
                                        .accessibilityHidden(true)
                                })
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityAddTraits(chosen.contains(f.id) ? .isSelected : [])
                    }
                }
                if model.etaFailed {
                    Group {
                        if model.etaLimited {
                            Text("You're doing that a lot. Try again in a few minutes.", bundle: .module)
                        } else {
                            Text("Couldn't send it. Try again.", bundle: .module)
                        }
                    }
                    .typeStyle(.foot).foregroundStyle(Color.brake)
                    .padding(.horizontal, Space.margin)
                }
                PrimaryButton("Send", isLoading: model.sendingETA) {
                    let users = Array(chosen)
                    Task {
                        await model.shareETA(with: users)
                        if model.etaSent != nil { dismiss() }
                    }
                }
                .disabled(chosen.isEmpty)
                .padding(.horizontal, Space.margin)
                .padding(.bottom, Space.s12)
            }
        }
    }
}

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
