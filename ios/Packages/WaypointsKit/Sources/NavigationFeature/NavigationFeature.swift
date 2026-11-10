import AVFoundation
import Core
import DesignSystem
import MapKit
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
    var me: CLLocationCoordinate2D?
    var heading: Double = 0
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
        if let me = await env.auth.currentSession()?.userID { cars = (try? await env.garage.cars(of: me)) ?? [] }
        calculate(from: nil)
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
        if !guiding { selected = bestIndex() }
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

        // Off route: > 40 m for 5 s; at most one request every 8 s.
        if best.dist > 40 {
            offSince = offSince ?? .now
            if let since = offSince, Date.now.timeIntervalSince(since) > 5, Date.now.timeIntervalSince(lastReroute) > 8 {
                lastReroute = .now
                rerouting = true
                calculate(from: here)
            }
        } else {
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
                        if mark == 25 { say(text, key: key) } else { say("In \(Self.distance(mark)), \(text.prefix(1).lowercased() + text.dropFirst())", key: key) }
                        break
                    }
                }
            }
        }

        // Hazard ahead within 250 m for a non-stock car.
        if clearance != .stock {
            let ahead = r.clearanceHazards(for: clearance).first { h in
                let d = loc.distance(from: CLLocation(latitude: h.coordinate.latitude, longitude: h.coordinate.longitude))
                return d < 250
            }
            if let ahead, hazardAhead?.id != ahead.id {
                hazardAhead = ahead
                say("\(Self.kindName(ahead.kind)) ahead", key: "h-\(ahead.id)")
            } else if ahead == nil {
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

    static func distance(_ meters: Double) -> String {
        let f = MeasurementFormatter()
        f.unitOptions = .naturalScale
        f.numberFormatter.maximumFractionDigits = 1
        let usesMetric = Locale.current.measurementSystem == .metric
        if usesMetric { return f.string(from: Measurement<UnitLength>(value: meters.rounded(), unit: .meters)) }
        let feet = meters * 3.28084
        return feet < 1000 ? "\(Int((feet / 50).rounded() * 50)) feet" : f.string(from: Measurement<UnitLength>(value: meters / 1609.344, unit: .miles))
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
                        .stroke(i == model.selected ? Color.sodium : Color.dust, lineWidth: i == model.selected ? 6 : 4)
                    ForEach(r.clearanceHazards(for: model.clearance)) { h in
                        Annotation("", coordinate: h.coordinate.cl) { ReportBadge(kind: h.kind.rawValue).scaleEffect(0.7) }
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
                ErrorState(Text("Couldn't find a route there.")) { model.calculate(from: nil) }
            } else {
                let best = model.bestIndex()
                ForEach(Array(model.routes.enumerated()), id: \.element.id) { i, r in
                    Button { model.selected = i } label: { row(r, best: i == best && model.clearance != .stock, selected: i == model.selected) }
                        .buttonStyle(RowButtonStyle())
                }
                if model.clearance != .stock, model.routes.allSatisfy({ !$0.clearanceHazards(for: model.clearance).isEmpty }) {
                    Text("No route avoids these. Apple Maps routing can't be steered around them.")
                        .typeStyle(.foot).foregroundStyle(Color.dust)
                }
                PrimaryButton("Go") { model.start() }
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
                if best { Text("Best for your car").typeStyle(.label).foregroundStyle(Color.go) }
            }
            Text(verbatim: "\(NavigationModel.distance(r.route.distance)) · \(r.route.name)").typeStyle(.sub).foregroundStyle(Color.dust)
            if model.clearance != .stock {
                if hazards.isEmpty {
                    Text("Clear for a \(model.clearance.rawValue) car").typeStyle(.sub).foregroundStyle(Color.go)
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

    var body: some View {
        ZStack {
            Map(position: $position) {
                UserAnnotation()
                if let r = model.current { MapPolyline(r.route.polyline).stroke(Color.sodium, lineWidth: 6) }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted))
            .ignoresSafeArea()
            VStack(spacing: 0) {
                banner
                if let h = model.hazardAhead {
                    Text(verbatim: "\(NavigationModel.kindName(h.kind)) ahead").typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                        .frame(maxWidth: .infinity).padding(Space.s8).background(Color.sodium)
                        .padding(.horizontal, Space.margin)
                }
                Spacer()
                HStack {
                    Text(verbatim: String(format: "%.0f", Locale.current.measurementSystem == .metric ? model.speed * 3.6 : model.speed * 2.23694))
                        .typeStyle(.readoutXL).foregroundStyle(Color.chalk)
                        .padding(.horizontal, Space.s16)
                        .background(Color.tarmac, in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, Space.margin)
                bottomBar
            }
        }
        .haptic(.warn, trigger: model.hazardAhead?.id)
    }

    private var banner: some View {
        let steps = model.current?.route.steps ?? []
        let next = steps.indices.contains(model.stepIndex + 1) ? steps[model.stepIndex + 1] : steps.last
        return HStack(spacing: Space.s12) {
            Image(systemName: arrow(next?.instructions ?? "")).font(.system(size: Size.hitTarget * 0.8, weight: .bold))
                .foregroundStyle(Color.sodium).frame(width: Size.hitTarget)
            VStack(alignment: .leading, spacing: Space.s2) {
                if model.arrived {
                    Text("You've arrived").typeStyle(.title).foregroundStyle(Color.chalk)
                    Text(verbatim: model.name ?? "").typeStyle(.bodyStrong).foregroundStyle(Color.dust)
                } else {
                    Text(verbatim: NavigationModel.distance(model.toManeuver)).typeStyle(.readoutL).foregroundStyle(Color.chalk)
                    Text(verbatim: model.rerouting ? "Rerouting" : (next?.instructions ?? "")).typeStyle(.bodyStrong)
                        .foregroundStyle(Color.chalk).lineLimit(2)
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
            let eta = Date.now.addingTimeInterval((model.current?.route.expectedTravelTime ?? 0) * (model.remaining / max(model.current?.route.distance ?? 1, 1)))
            VStack(alignment: .leading) {
                Text(verbatim: eta.formatted(date: .omitted, time: .shortened)).typeStyle(.readoutM).foregroundStyle(Color.chalk)
                Text(verbatim: NavigationModel.distance(model.remaining)).typeStyle(.foot).foregroundStyle(Color.dust)
            }
            Spacer()
            IconButton(model.muted ? "speaker.slash" : Symbol.speaker, label: model.muted ? "Unmute" : "Mute") { model.muted.toggle() }
            Button("End", action: end)
                .typeStyle(.bodyStrong).foregroundStyle(Color.brake)
                .frame(width: Size.row * 1.6, height: Size.control)
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

extension Coordinate {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
