import Core
import DesignSystem
import SwiftUI
import UIKit

// MARK: ROAD-6 Loops
// Saved roads grouped in order under a name. Lengths only: no speed, time, or ranking.

/// Google encoded polyline, precision 5: the convoy route format (`ConvoyState.routePolyline`),
/// the same one a cruise's saved road is sent in (MEET-13).
enum Polyline {
    /// Keeps a long loop under the gateway's route cap.
    static let maxPoints = 4000

    /// The loop's roads joined end to end in order. A road is drawn in whichever direction it
    /// was recorded, so each one is reversed when that connects it to the road before it; the
    /// first road keeps its saved direction. Where roads don't quite touch, the closer end wins
    /// and navigation routes the gap.
    static func joined(_ roads: [Road]) -> [Coordinate] {
        var path: [Coordinate] = []
        var end: Coordinate?
        for road in roads {
            var p = road.path
            guard let first = p.first, let last = p.last else { continue }
            if let end, end.distance(to: last) < end.distance(to: first) { p.reverse() }
            path.append(contentsOf: p)
            end = p.last
        }
        return path
    }

    /// `joined(_:)`, thinned evenly when there are more than `maxPoints`.
    static func path(of roads: [Road]) -> [Coordinate] {
        let path = joined(roads)
        let every = max(1, (path.count + maxPoints - 1) / maxPoints)
        return path.enumerated().filter { $0.offset % every == 0 || $0.offset == path.count - 1 }.map(\.element)
    }

    static func encode(_ path: [Coordinate]) -> String {
        var out = ""
        var lastLat = 0, lastLng = 0
        for c in path {
            let lat = Int((c.latitude * 1e5).rounded()), lng = Int((c.longitude * 1e5).rounded())
            append(lat - lastLat, to: &out)
            append(lng - lastLng, to: &out)
            lastLat = lat; lastLng = lng
        }
        return out
    }

    private static func append(_ delta: Int, to out: inout String) {
        var v = delta < 0 ? ~(delta << 1) : delta << 1
        while v >= 0x20 {
            out.unicodeScalars.append(Unicode.Scalar(UInt8((0x20 | (v & 0x1f)) + 63)))
            v >>= 5
        }
        out.unicodeScalars.append(Unicode.Scalar(UInt8(v + 63)))
    }
}

/// Your loops, shared by the list in the map sheet and the loop sheet that edits them.
@MainActor @Observable
final class LoopStore {
    static let shared = LoopStore()
    var loops: [RoadLoop]?
    var failed = false

    func load(_ env: AppEnvironment) async {
        failed = false
        do { loops = try await env.roads.myLoops() } catch { failed = loops == nil }
    }
}

/// The "LOOPS" block of the map sheet's drives section.
struct LoopsList: View {
    let env: AppEnvironment
    @State private var store = LoopStore.shared
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("LOOPS")
            if let loops = store.loops {
                if loops.isEmpty {
                    Text("No loops yet. Group your saved roads into one drive.", bundle: .module)
                        .typeStyle(.foot).foregroundStyle(Color.dust).padding(.horizontal, Space.margin)
                }
                ForEach(loops) { l in
                    Button { env.router.open(.loop(l.id)) } label: {
                        Row(Text(verbatim: l.name), trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                }
                Button { creating = true } label: {
                    Row(Text("New loop", bundle: .module), trailing: { Image.symbol(Symbol.add) })
                }
                .buttonStyle(RowButtonStyle())
            } else if store.failed {
                VStack(alignment: .leading, spacing: Space.s8) {
                    Text("Couldn't load your loops.", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    SecondaryButton("Try again") { Task { await store.load(env) } }
                }
                .padding(.horizontal, Space.margin)
            } else {
                SkeletonRow(hasLeading: false)
            }
        }
        .task { await store.load(env) }
        .sheet(isPresented: $creating) { LoopEditor(env: env, loop: nil, roads: []) { _ in } }
    }
}

/// ROAD-9: the road sheet's "Add to a loop" chooser. Loops already holding this road are
/// marked and disabled; "New loop" opens the editor with this road already picked.
struct AddToLoop: View {
    let env: AppEnvironment
    let road: Road
    let onAdded: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loops: [RoadLoop]?
    @State private var failed = false
    @State private var creating = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Sheet(Text("Add to a loop", bundle: .module)) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s8) {
                    if let loops {
                        if loops.isEmpty {
                            Text("No loops yet. Start one with this road.", bundle: .module)
                                .typeStyle(.body).foregroundStyle(Color.dust)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(loops) { l in
                                let contains = l.roadIDs.contains(road.id)
                                let full = l.roadIDs.count >= LoopEditor.maxRoads
                                Button { add(to: l) } label: {
                                    Row(Text(verbatim: l.name),
                                        subtitle: Text("\(l.roadIDs.count.formatted(.number)) roads", bundle: .module),
                                        trailing: {
                                            if contains {
                                                Text("Added", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                                            } else if full {
                                                Text("Full", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                                            } else {
                                                Image.symbol(Symbol.add)
                                            }
                                        })
                                }
                                .buttonStyle(RowButtonStyle())
                                .disabled(contains || full || working)
                            }
                            Button { creating = true } label: {
                                Row(Text("New loop", bundle: .module), trailing: { Image.symbol(Symbol.add) })
                            }
                            .buttonStyle(RowButtonStyle())
                            .disabled(working)
                        }
                        .padding(.horizontal, -Space.margin)
                    } else if failed {
                        Text("Couldn't load your loops.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                        SecondaryButton("Try again") { Task { await load() } }
                    } else {
                        SkeletonRow(hasLeading: false)
                    }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
        .sheet(isPresented: $creating) {
            LoopEditor(env: env, loop: nil, roads: [road]) { saved in
                onAdded(saved.name)
                dismiss()
            }
        }
    }

    private func load() async {
        failed = false
        loops = try? await env.roads.myLoops()
        failed = loops == nil
    }

    private func add(to loop: RoadLoop) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                var l = loop
                l.roadIDs.append(road.id)
                try await env.roads.saveLoop(l)
                await LoopStore.shared.load(env)
                onAdded(l.name)
                dismiss()
            } catch {
                self.error = message(for: error, fallback: String(localized: "Couldn't add it to the loop. Check your connection and try again.", bundle: .module))
                working = false
            }
        }
    }
}

/// A loop: its roads in order, the total length, and what you can do with it. Opened by
/// `Route.loop`, so a share link lands here too.
struct LoopDetail: View {
    let env: AppEnvironment
    let loopID: LoopID
    @Environment(\.dismiss) private var dismiss
    @State private var loop: RoadLoop?
    @State private var roads: [Road] = []
    @State private var me: UserID?
    @State private var failed = false
    @State private var blocked = false
    @State private var editing = false
    @State private var working = false
    @State private var error: String?
    @State private var done = 0
    @State private var shared: SharedImage?
    @State private var drivenCount = 0
    @Environment(\.displayScale) private var displayScale

    private var mine: Bool { loop != nil && loop?.ownerID == me }

    var body: some View {
        Sheet(loop.map { Text(verbatim: $0.name) } ?? Text("Loop", bundle: .module), trailing: {
            HStack(spacing: 0) {
                if let loop {
                    // ROAD-8: share the loop as a card.
                    IconButton(Symbol.share, label: "Share loop") { share(loop) }
                }
                if let loop, !mine, !blocked {
                    Menu {
                        Button("Report") { env.router.open(.reportContent(ContentRef(kind: .user, id: loop.ownerID.description))) }
                        Button("Block", role: .destructive) { block(loop.ownerID) }
                    } label: { Image.symbol(Symbol.more).foregroundStyle(Color.chalk).frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget) }
                    .accessibilityLabel(Text("More options", bundle: .module))
                }
            }
        }, content: {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    if blocked {
                        Text("You blocked the person who made this loop.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                    } else if let loop {
                        content(loop)
                    } else if failed {
                        Text("Couldn't load this loop. It may have been deleted.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                        SecondaryButton("Try again") { Task { await load() } }
                    } else {
                        SkeletonRow(hasLeading: false)
                    }
                }
                .padding(Space.margin)
            }
        })
        .presentationDetents([.large])
        .haptic(.done, trigger: done)
        .task { await load() }
        .sheet(isPresented: $editing) {
            if let loop {
                LoopEditor(env: env, loop: loop, roads: roads) { saved in
                    self.loop = saved
                    Task { await load() }
                }
            }
        }
        .sheet(item: $shared) { ShareSheet(items: [$0.image]).presentationDetents([.medium, .large]) }
    }

    @ViewBuilder private func content(_ loop: RoadLoop) -> some View {
        let total = Units.length(roads.reduce(0) { $0 + $1.lengthMeters })
        Readout(total.value, unit: total.unit, label: "TOTAL LENGTH")
        if drivenCount > 0 {
            Text("You've driven this loop \(drivenCount)×", bundle: .module)
                .typeStyle(.sub).foregroundStyle(Color.dust)
        }
        if roads.isEmpty {
            Text("The roads in this loop are no longer available.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(roads.enumerated()), id: \.element.id) { i, r in
                    let len = Units.length(r.lengthMeters)
                    Row(Text(verbatim: "\(i + 1). \(r.name)"),
                        trailing: { Text(readout: "\(len.value) \(len.unit)", token: .readoutS) })
                }
            }
            .padding(.horizontal, -Space.margin)
            HStack(spacing: Space.s12) {
                PrimaryButton("Drive it") {
                    let path = Polyline.joined(roads)
                    guard path.count > 1 else { return }
                    dismiss()
                    env.router.open(.navigatePath(path: path, name: loop.name))
                }
                SecondaryButton("Send to convoy", isLoading: working) { sendToConvoy(loop) }
            }
            Text("Drive it follows the whole loop. Send to convoy starts a convoy with the whole loop as its route.", bundle: .module)
                .typeStyle(.foot).foregroundStyle(Color.dust)
        }
        if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
        if let url = Route.loop(loop.id).shareURL {
            ShareLink(item: url) {
                Text("Share loop", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.sodium)
                    .frame(minHeight: Size.hitTarget).contentShape(Rectangle())
            }
        }
        if mine {
            SecondaryButton("Edit") { editing = true }
            DestructiveButton("Delete loop", confirmTitle: "Delete loop", consequence: "The loop is removed. Its roads stay.") {
                Task {
                    do {
                        try await env.roads.deleteLoop(loop.id)
                        await LoopStore.shared.load(env)
                        dismiss()
                    } catch {
                        self.error = message(for: error, fallback: String(localized: "Couldn't delete the loop. Check your connection and try again.", bundle: .module))
                    }
                }
            }
        }
    }

    private func load() async {
        failed = false
        me = await env.auth.currentSession()?.userID
        guard let l = try? await env.roads.loop(loopID) else { failed = loop == nil; return }
        // SAFE-3: a loop whose owner the user reported is gone for them, as are reported roads.
        let hidden = (try? await env.safety.reportedTargets()) ?? []
        if hidden.contains(ContentRef(kind: .user, id: l.ownerID.description)) {
            loop = nil
            failed = true
            return
        }
        var list: [Road] = []
        for id in l.roadIDs {
            if let r = try? await env.roads.road(id),
               !hidden.contains(ContentRef(kind: .road, id: r.id.description)),
               !hidden.contains(ContentRef(kind: .user, id: r.authorID.description)) { list.append(r) }
        }
        loop = l
        roads = list
        if !list.isEmpty {
            let path = Polyline.path(of: list)
            drivenCount = await Task.detached(priority: .utility) { Self.drivenCount(on: path) }.value
        }
    }

    /// ROAD-11: the ROAD-10 rule on the loop's joined path — a saved drive counts once when
    /// at least two of its points are within 100 m of it (sampled to keep it cheap). Reads
    /// files off-actor.
    nonisolated private static func drivenCount(on path: [Coordinate]) -> Int {
        let step = max(1, path.count / 200)
        let sampled = stride(from: 0, to: path.count, by: step).map { path[$0] }
        return DriveRecorder.load().count { d in
            d.points.filter { p in sampled.contains(where: { p.distance(to: $0) < 100 }) }.count >= 2
        }
    }

    /// ROAD-8: renders the loop card and hands it to the share sheet.
    private func share(_ loop: RoadLoop) {
        Task {
            let owner = try? await env.profiles.profile(loop.ownerID)
            let image = await LoopShare.render(name: loop.name, roads: roads, handle: owner?.handle, scale: displayScale)
            if let image { shared = SharedImage(image: image) }
        }
    }

    /// The MEET-13 mechanism: a convoy named for the loop, with the loop as its route and the
    /// last road's end as its destination; joins you, then opens it.
    private func sendToConvoy(_ loop: RoadLoop) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                let path = Polyline.path(of: roads)
                guard path.count > 1 else {
                    self.error = String(localized: "That loop has no route yet. Add a road first.", bundle: .module)
                    working = false
                    return
                }
                let end = path.last.map { ConvoyDestination(coordinate: $0, name: roads.last?.name ?? loop.name) }
                let invite = try await env.gateway.createConvoy(name: String(loop.name.prefix(40)), destination: end,
                                                                routePolyline: Polyline.encode(path))
                await env.realtime.joinConvoy(invite.id)
                done += 1
                env.router.open(.joinConvoy(code: invite.joinCode))
            } catch {
                self.error = message(for: error, fallback: String(localized: "Couldn't start the convoy. Check your connection and try again.", bundle: .module))
            }
            working = false
        }
    }

    private func block(_ owner: UserID) {
        Task {
            do {
                try await env.safety.block(owner)
                blocked = true
            } catch {
                self.error = message(for: error, fallback: String(localized: "Couldn't block them. Check your connection and try again.", bundle: .module))
            }
        }
    }
}

/// Create a loop, or rename, reorder, and change the roads of one. `loop` is nil for a new one.
struct LoopEditor: View {
    let env: AppEnvironment
    let loop: RoadLoop?
    let onSaved: (RoadLoop) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var picked: [Road]
    @State private var saved: [Road]?
    @State private var failed = false
    @State private var saving = false
    @State private var error: String?

    /// `road_loops.road_ids` holds at most this many.
    static let maxRoads = 20

    init(env: AppEnvironment, loop: RoadLoop?, roads: [Road], onSaved: @escaping (RoadLoop) -> Void) {
        self.env = env
        self.loop = loop
        self.onSaved = onSaved
        _name = State(initialValue: loop?.name ?? "")
        _picked = State(initialValue: roads)
    }

    var body: some View {
        Sheet(loop == nil ? Text("New loop", bundle: .module) : Text("Edit loop", bundle: .module)) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s16) {
                    Field("Name", text: $name, prompt: "Like 'Sunday pines loop'", limit: 50)
                    Text("In this loop, in order", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    if picked.isEmpty {
                        Text("Add a road from your saved roads below.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                    }
                    ForEach(Array(picked.enumerated()), id: \.element.id) { i, r in
                        HStack(spacing: 0) {
                            Text(verbatim: "\(i + 1). \(r.name)").typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            IconButton("chevron.up", label: "Move up") { picked.swapAt(i, i - 1) }
                                .accessibilityLabel(Text("Move \(r.name) up", bundle: .module))
                                .disabled(i == 0)
                            IconButton("chevron.down", label: "Move down") { picked.swapAt(i, i + 1) }
                                .accessibilityLabel(Text("Move \(r.name) down", bundle: .module))
                                .disabled(i == picked.count - 1)
                            IconButton(Symbol.delete, label: "Remove from loop") { picked.remove(at: i) }
                                .accessibilityLabel(Text("Remove \(r.name) from the loop", bundle: .module))
                        }
                    }
                    let total = Units.length(picked.reduce(0) { $0 + $1.lengthMeters })
                    Readout(total.value, unit: total.unit, label: "TOTAL LENGTH")
                    Text("Your saved roads", bundle: .module).typeStyle(.foot).foregroundStyle(Color.dust)
                    if let saved {
                        let rest = saved.filter { r in !picked.contains { $0.id == r.id } }
                        if saved.isEmpty {
                            Text("You have no saved roads yet. Record a drive, then save a stretch of it.", bundle: .module)
                                .typeStyle(.body).foregroundStyle(Color.dust)
                        } else if rest.isEmpty {
                            Text("Every road you saved is in this loop.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rest) { r in
                                let len = Units.length(r.lengthMeters)
                                Button { if picked.count < Self.maxRoads { picked.append(r) } } label: {
                                    Row(Text(verbatim: r.name), subtitle: Text(verbatim: "\(len.value) \(len.unit)"),
                                        trailing: { Image.symbol(Symbol.add) })
                                }
                                .buttonStyle(RowButtonStyle())
                            }
                        }
                        .padding(.horizontal, -Space.margin)
                    } else if failed {
                        Text("Couldn't load your saved roads.", bundle: .module).typeStyle(.body).foregroundStyle(Color.dust)
                        SecondaryButton("Try again") { Task { await loadSaved() } }
                    } else {
                        SkeletonRow(hasLeading: false)
                    }
                    if let error { Text(verbatim: error).typeStyle(.foot).foregroundStyle(Color.brake) }
                    PrimaryButton("Save loop", isLoading: saving) { save() }
                        .disabled(name.isEmpty || picked.isEmpty)
                }
                .padding(Space.margin)
            }
        }
        .presentationDetents([.large])
        .task { await loadSaved() }
    }

    private func loadSaved() async {
        failed = false
        guard let me = await env.auth.currentSession()?.userID, let list = try? await env.roads.roads(by: me) else {
            failed = true
            return
        }
        saved = list
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            do {
                guard let me = await env.auth.currentSession()?.userID else { throw WaypointsError.notSignedIn }
                var l = loop ?? RoadLoop(ownerID: me, name: name, roadIDs: [])
                l.name = name
                l.roadIDs = picked.map(\.id)
                let result = try await env.roads.saveLoop(l)
                await LoopStore.shared.load(env)
                onSaved(result)
                dismiss()
            } catch {
                self.error = message(for: error, fallback: String(localized: "Couldn't save the loop. Check your connection and try again.", bundle: .module))
            }
            saving = false
        }
    }
}

// MARK: ROAD-8 Share loop card

/// Every road in the loop stroked in sodium, drawn to scale: one bounding box over all the
/// coordinates, mapped lng→x, lat→−y with a uniform scale and centered in the canvas frame.
/// The same sodium the roads layer uses on the map (`RoadsLayer` tint).
struct LoopRoadsShape: Shape {
    let paths: [[Coordinate]]

    func path(in rect: CGRect) -> Path {
        let all = paths.flatMap { $0 }
        guard let minLng = all.map(\.longitude).min(), let maxLng = all.map(\.longitude).max(),
              let minLat = all.map(\.latitude).min(), let maxLat = all.map(\.latitude).max() else { return Path() }
        let dLng = max(maxLng - minLng, 1e-9), dLat = max(maxLat - minLat, 1e-9)
        let scale = min(rect.width / dLng, rect.height / dLat)
        let x = { rect.midX + ($0 - (minLng + dLng / 2)) * scale }
        let y = { rect.midY - ($0 - (minLat + dLat / 2)) * scale }
        var out = Path()
        for path in paths {
            guard let first = path.first else { continue }
            out.move(to: CGPoint(x: x(first.longitude), y: y(first.latitude)))
            for c in path.dropFirst() { out.addLine(to: CGPoint(x: x(c.longitude), y: y(c.latitude))) }
        }
        return out
    }
}

/// The card a loop shares as: the joined polylines to scale over concrete, a sodium paint bar,
/// the loop name, the road count, the owner's handle.
struct LoopCard: View {
    let name: String
    let roads: [Road]
    let handle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            ZStack(alignment: .bottom) {
                ZStack {
                    Color.concrete
                    LoopRoadsShape(paths: roads.map(\.path))
                        .stroke(Color.sodium, style: StrokeStyle(lineWidth: Size.paintBar, lineCap: .round, lineJoin: .round))
                        .padding(Space.s12)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipped()
                Rectangle().fill(Color.sodium).frame(height: Size.paintBar)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(verbatim: name).typeStyle(.title).foregroundStyle(Color.chalk)
                Text("\(roads.count) roads", bundle: .module).typeStyle(.sub).foregroundStyle(Color.dust)
            }
            HStack {
                if let handle { Text(verbatim: "@\(handle)").typeStyle(.readoutS).foregroundStyle(Color.sodium) }
                Spacer()
                Text(verbatim: "Waypoints").typeStyle(.label).foregroundStyle(Color.dust)
            }
        }
        .padding(Space.margin)
        .frame(width: Size.row * 7)
        .background(Color.asphalt)
    }
}

/// A shared image, identifiable so it can drive `.sheet(item:)`.
struct SharedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// The system share sheet for an image.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

@MainActor
enum LoopShare {
    static func render(name: String, roads: [Road], handle: String?, scale: CGFloat) -> UIImage? {
        let renderer = ImageRenderer(content: LoopCard(name: name, roads: roads, handle: handle)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        return renderer.uiImage
    }
}

/// Debug screens `loop` and `loop-edit`: your first loop.
struct DebugLoop: View {
    let env: AppEnvironment
    let edit: Bool
    @State private var loop: RoadLoop?
    @State private var roads: [Road] = []

    var body: some View {
        Group {
            if let loop {
                if edit { LoopEditor(env: env, loop: loop, roads: roads) { _ in } } else { LoopDetail(env: env, loopID: loop.id) }
            } else {
                SkeletonRow(hasLeading: false)
            }
        }
        .task {
            guard let first = try? await env.roads.myLoops().first else { return }
            var list: [Road] = []
            for id in first.roadIDs {
                if let r = try? await env.roads.road(id) { list.append(r) }
            }
            roads = list
            loop = first
        }
    }
}
