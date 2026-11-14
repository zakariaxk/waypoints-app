import Core
import DesignSystem
import MapKit
import SwiftUI

/// Rated roads (plan 10.3 M11): a map layer, road detail with ratings, and on-device drive
/// recording (opt-in in S2, "Record my drives on this phone"). Traces never leave the phone
/// until a stretch is saved.
public enum RoadsFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerMapLayer(RoadsLayer(env: env))
        registry.registerMapLayer(DrivenLayer())
        registry.registerMapSheetSection(DrivesSection(env: env))
        DriveRecorder.shared.start(env: env)
    }
}

/// SET-3: lengths follow the device's locale.
enum Units {
    static var metric: Bool { Locale.current.measurementSystem == .metric }
    static func length(_ meters: Int) -> (value: String, unit: String) {
        let v = Double(meters) / (metric ? 1000 : 1609.344)
        return (v.formatted(.number.precision(.fractionLength(1))), metric ? "km" : "mi")
    }
}

/// SAFE-9: the server's abuse limits get their own line; everything else gets the fallback.
func message(for error: any Error, fallback: String) -> String {
    (error as? WaypointsError) == .rateLimited ? String(localized: "You're doing that a lot. Try again in a few minutes.") : fallback
}

/// One recorded drive, stored as a file in Application Support.
struct Drive: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var startedAt: Date
    var points: [Coordinate]
}

@MainActor
final class DriveRecorder {
    static let shared = DriveRecorder()
    private var current: Drive?
    private var lastAt: Date?
    private var started = false

    private var folder: URL { Self.folder }

    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "drives")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func start(env: AppEnvironment) {
        guard !started else { return }
        started = true
        Task {
            for await s in await env.location.samples() {
                guard UserDefaults.standard.bool(forKey: "recordDrives"), s.speed > 3 else { continue }
                record(s.coordinate, at: s.timestamp)
            }
        }
    }

    private func record(_ c: Coordinate, at t: Date) {
        if let last = lastAt, t.timeIntervalSince(last) > 300 { flush(); current = nil }
        if current == nil { current = Drive(id: UUID().uuidString, startedAt: t, points: []) }
        if let p = current?.points.last, p.distance(to: c) < 15 { return }
        current?.points.append(c)
        lastAt = t
        if (current?.points.count ?? 0) % 20 == 0 { flush() }
    }

    private func flush() {
        guard let d = current, d.points.count > 10, let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: folder.appending(path: "\(d.id).json"), options: .atomic)
    }

    func drives() -> [Drive] { Self.load() }

    /// Reads every saved trace; callable off the main actor (ROAD-5).
    nonisolated static func load() -> [Drive] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { try? JSONDecoder().decode(Drive.self, from: Data(contentsOf: $0)) }.sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ d: Drive) { try? FileManager.default.removeItem(at: folder.appending(path: "\(d.id).json")) }
}

// MARK: ROAD-5 Driven map

/// A plain lat/lng grid (0.0025 degree, about 280 m north to south), computed on this phone
/// from the drive traces. Nothing here leaves the device. Counts cells, never speed or time.
enum DrivenGrid {
    struct Cell: Hashable, Sendable { let i: Int; let j: Int }
    static let step = 0.0025

    static func cell(_ c: Coordinate) -> Cell { Cell(i: Int((c.latitude / step).rounded(.down)), j: Int((c.longitude / step).rounded(.down))) }
    static func center(_ c: Cell) -> Coordinate { Coordinate(latitude: (Double(c.i) + 0.5) * step, longitude: (Double(c.j) + 0.5) * step) }

    /// Cells a path passes through, filling gaps between points every 100 m.
    static func cells(along path: [Coordinate]) -> Set<Cell> {
        var out = Set<Cell>()
        guard let first = path.first else { return out }
        out.insert(cell(first))
        for (a, b) in zip(path, path.dropFirst()) {
            let n = max(1, Int(a.distance(to: b) / 100))
            for k in 1...n {
                let t = Double(k) / Double(n)
                out.insert(cell(Coordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                           longitude: a.longitude + (b.longitude - a.longitude) * t)))
            }
        }
        return out
    }

    static func contains(_ r: MapRegion, _ c: Cell) -> Bool {
        let p = center(c)
        return (r.minLatitude...r.maxLatitude).contains(p.latitude) && (r.minLongitude...r.maxLongitude).contains(p.longitude)
    }

    static func driven() -> Set<Cell> { DriveRecorder.load().reduce(into: Set<Cell>()) { $0.formUnion(cells(along: $1.points)) } }
}

/// Shades the cells you have driven in view. Off when drive recording is off.
struct DrivenLayer: MapLayerProvider {
    var id: String { "driven_map" }
    static let maxItems = 400

    func items(in region: MapRegion) -> AsyncStream<[MapItem]> {
        AsyncStream { c in
            let task = Task.detached(priority: .utility) {
                guard UserDefaults.standard.bool(forKey: "recordDrives") else { c.yield([]); c.finish(); return }
                let cells = DrivenGrid.driven().filter { DrivenGrid.contains(region, $0) }.sorted { ($0.i, $0.j) < ($1.i, $1.j) }
                let every = max(1, cells.count / Self.maxItems)
                let shown = cells.enumerated().filter { $0.offset % every == 0 }.map(\.element)
                c.yield(shown.map { cell in
                    MapItem(id: "driven.\(cell.i).\(cell.j)", coordinate: DrivenGrid.center(cell), glyph: "driven", tint: .sodium,
                            title: String(localized: "Driven"), priority: 0)
                })
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor func detail(for item: MapItem) -> AnyView? { nil }
}

/// The number: the share of rated-road cells in view that you have driven.
struct DrivenShare: View {
    let env: AppEnvironment
    let region: MapRegion
    @State private var share: (driven: Int, total: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let share, share.total > 0 {
                SectionLabel("DRIVEN MAP")
                Readout("\(share.driven * 100 / share.total)", unit: "%", label: "OF RATED ROADS IN VIEW")
                    .padding(.horizontal, Space.margin)
                Text("\(share.driven) of \(share.total) stretches of road here. Counted on this phone only.")
                    .typeStyle(.foot).foregroundStyle(Color.dust).padding(.horizontal, Space.margin)
            }
        }
        .task(id: region) {
            guard UserDefaults.standard.bool(forKey: "recordDrives") else { share = nil; return }
            let roads = (try? await env.roads.roads(in: region)) ?? []
            let r = region
            share = await Task.detached(priority: .utility) {
                let road = roads.reduce(into: Set<DrivenGrid.Cell>()) { $0.formUnion(DrivenGrid.cells(along: $1.path)) }
                    .filter { DrivenGrid.contains(r, $0) }
                return (road.intersection(DrivenGrid.driven()).count, road.count)
            }.value
        }
    }
}

struct RoadsLayer: MapLayerProvider {
    let env: AppEnvironment
    var id: String { "rated_roads" }

    func items(in region: MapRegion) -> AsyncStream<[MapItem]> {
        AsyncStream { c in
            let task = Task {
                let roads = (try? await env.roads.roads(in: region)) ?? []
                c.yield(roads.compactMap { r in
                    guard !r.path.isEmpty else { return nil }
                    return MapItem(id: r.id.description, coordinate: r.path[r.path.count / 2], glyph: "road", tint: .sodium, title: r.name, priority: 1)
                })
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    @MainActor func detail(for item: MapItem) -> AnyView? {
        RoadID(string: item.id).map { AnyView(RoadDetail(env: env, roadID: $0)) }
    }
}

// MARK: M11 Road detail

struct RoadDetail: View {
    let env: AppEnvironment
    let roadID: RoadID
    @State private var road: Road?
    @State private var rating = RoadRating(surface: 3, scenery: 3, traffic: 3)
    @State private var ratingOpen = false
    @State private var done = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            if let r = road {
                Text(verbatim: r.name).typeStyle(.title).foregroundStyle(Color.chalk)
                let len = Units.length(r.lengthMeters)
                Readout(len.value, unit: len.unit, label: "LENGTH")
                bar("Surface", r.ratings.surface, count: r.ratings.count)
                bar("Scenery", r.ratings.scenery, count: r.ratings.count)
                bar("Traffic", r.ratings.traffic, count: r.ratings.count)
                HStack(spacing: Space.s12) {
                    PrimaryButton("Drive it") { if let start = r.path.first { env.router.open(.navigate(to: start, name: r.name)) } }
                    SecondaryButton("Rate") { ratingOpen.toggle() }
                }
                if ratingOpen {
                    RatingSteppers(rating: $rating)
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Save") {
                        Task {
                            do {
                                try await env.roads.rate(roadID, rating)
                                error = nil
                                done += 1
                                ratingOpen = false
                                road = try? await env.roads.road(roadID)
                            } catch {
                                self.error = message(for: error, fallback: "Couldn't save the rating. Check your connection and try again.")
                            }
                        }
                    }
                }
            } else {
                SkeletonRow()
            }
        }
        .padding(.horizontal, Space.margin)
        .haptic(.done, trigger: done)
        .task {
            road = try? await env.roads.road(roadID)
            if let mine = try? await env.roads.myRating(for: roadID) { rating = mine }
        }
    }

    private func bar(_ title: LocalizedStringKey, _ value: Double, count: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text(title).typeStyle(.sub).foregroundStyle(Color.chalk)
                Spacer()
                Text(verbatim: count == 0 ? "No ratings" : String(format: "%.1f · %d", value, count)).typeStyle(.readoutS).foregroundStyle(Color.dust)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.curb)
                    Capsule().fill(Color.sodium).frame(width: g.size.width * value / 5)
                }
            }
            .frame(height: Size.rangeBar)
        }
    }
}

struct RatingSteppers: View {
    @Binding var rating: RoadRating
    var body: some View {
        VStack(spacing: 0) {
            stepper("Surface", $rating.surface)
            stepper("Scenery", $rating.scenery)
            stepper("Traffic", $rating.traffic)
        }
    }
    private func stepper(_ t: LocalizedStringKey, _ v: Binding<Int>) -> some View {
        Row(Text(t), trailing: {
            Stepper(value: v, in: 1...5) { Text(verbatim: "\(v.wrappedValue)").typeStyle(.readoutM) }
        })
    }
}

// MARK: Drives

struct DrivesSection: MapSheetSection {
    let env: AppEnvironment
    var id: String { "drives" }
    var order: Int { 60 }
    @MainActor func view(region: MapRegion) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 0) {
            DrivenShare(env: env, region: region)
            DrivesView(env: env)
        })
    }
}

struct DrivesView: View {
    let env: AppEnvironment
    @State private var drives: [Drive] = []
    @State private var open: Drive?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !drives.isEmpty {
                SectionLabel("YOUR DRIVES")
                ForEach(drives.prefix(5)) { d in
                    Button { open = d } label: {
                        Row(Text(verbatim: d.startedAt.formatted(date: .abbreviated, time: .shortened)),
                            trailing: { Text(verbatim: "Save a stretch").typeStyle(.foot).foregroundStyle(Color.sodium) })
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
        .onAppear { drives = DriveRecorder.shared.drives() }
        .sheet(item: $open) { d in SaveStretch(env: env, drive: d) }
    }
}

struct SaveStretch: View {
    let env: AppEnvironment
    let drive: Drive
    @Environment(\.dismiss) private var dismiss
    @State private var from = 0.0
    @State private var to = 1.0
    @State private var name = ""
    @State private var rating = RoadRating(surface: 3, scenery: 3, traffic: 3)
    @State private var saving = false
    @State private var error: String?
    @State private var zones: [HomeZone] = []

    /// ROAD-3: a stretch may not start or end inside one of your home zones.
    private var endsAtHome: Bool {
        guard let a = stretch.first, let b = stretch.last else { return false }
        return zones.contains { z in
            a.distance(to: z.center) <= Double(z.radiusMeters) || b.distance(to: z.center) <= Double(z.radiusMeters)
        }
    }

    private var stretch: [Coordinate] {
        let n = drive.points.count
        let a = Int(from * Double(n - 1)), b = max(a + 1, Int(to * Double(n - 1)))
        return Array(drive.points[a...min(b, n - 1)])
    }

    var body: some View {
        Sheet(Text("Save a road")) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Map {
                        MapPolyline(coordinates: drive.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                            .stroke(Color.dust, lineWidth: 3)
                        MapPolyline(coordinates: stretch.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
                            .stroke(Color.sodium, lineWidth: 6)
                    }
                    .frame(height: Size.row * 4)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.r20))
                    .environment(\.colorScheme, .dark)
                    Text("Start").typeStyle(.foot).foregroundStyle(Color.dust)
                    Slider(value: $from, in: 0...max(0, to - 0.02)).tint(.sodium)
                    Text("End").typeStyle(.foot).foregroundStyle(Color.dust)
                    Slider(value: $to, in: min(1, from + 0.02)...1).tint(.sodium)
                    Field("Name", text: $name, prompt: "Like 'Route 9 through the pines'", limit: 50)
                    RatingSteppers(rating: $rating)
                    if endsAtHome {
                        Text("A road can't start or end in one of your home zones. Move the handles.")
                            .typeStyle(.foot).foregroundStyle(Color.brake)
                    }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Save road", isLoading: saving) {
                        guard !endsAtHome else { return }
                        saving = true
                        Task {
                            do {
                                let road = try await env.roads.createRoad(name: name, path: stretch)
                                try await env.roads.rate(road.id, rating)
                                dismiss()
                            } catch {
                                self.error = message(for: error, fallback: "Couldn't save the road. Check your connection and try again.")
                            }
                            saving = false
                        }
                    }
                    .disabled(name.isEmpty || stretch.count < 2 || endsAtHome)
                    DestructiveButton("Delete this drive", confirmTitle: "Delete drive", consequence: "The trace is removed from this phone.") {
                        DriveRecorder.shared.delete(drive)
                        dismiss()
                    }
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
        .task { for await z in await env.location.homeZones() { zones = z } }
    }
}
