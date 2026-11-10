import Core
import DesignSystem
import EngineAudio
import PerformanceModel
import SwiftUI

/// The Strip (plan 10.8 G7–G9, 11.4): a virtual quarter mile driven by the same model as the
/// estimates. No GPS, real speed, or location is read here.
public enum RaceFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.race) { route in
            guard case let .race(id) = route else { return nil }
            return AnyView(Lobby(env: env, carID: id))
        }
    }
}

/// A recorded run's inputs, small enough for `race_results.input_log` (≤4 KB).
struct InputLog: Codable, Hashable {
    var launchRpm: Double
    var launchTick: Int
    var shifts: [Int]
    var lifts: [[Int]]           // [start, end) ticks with throttle off

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func decode(_ d: Data) -> InputLog? { try? JSONDecoder().decode(InputLog.self, from: d) }
}

enum Opponent: Hashable {
    case ghost(RaceResult)
    case house(String, VehicleSpec)

    var title: String {
        switch self {
        case .ghost: "Your best run"
        case let .house(name, _): name
        }
    }
}

let houseCars: [(String, VehicleSpec)] = [
    ("House car: commuter", VehicleSpec(hpCrank: 180, torqueLbFt: 180, weightLb: 3100, drivetrain: .fwd, redline: 6500, automatic: true)),
    ("House car: hot hatch", VehicleSpec(hpCrank: 300, torqueLbFt: 280, weightLb: 3200, drivetrain: .awd, aspiration: .turbo, redline: 6800)),
    ("House car: muscle", VehicleSpec(hpCrank: 480, torqueLbFt: 420, weightLb: 3800, redline: 7200, cylinders: 8, layout: .v, crankPlane: .cross)),
]

// MARK: G7 Lobby

struct Lobby: View {
    let env: AppEnvironment
    let carID: CarID
    @State private var car: Car?
    @State private var spec: VehicleSpec?
    @State private var best: RaceResult?
    @State private var past: [RaceResult] = []
    @State private var opponent: Opponent?
    @State private var running = false
    @State private var showPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s16) {
                Text("Virtual drag strip. A game, not a challenge. Keep it off the street.")
                    .typeStyle(.bodyStrong).foregroundStyle(Color.sodium)
                if let car, let spec {
                    let est = estimate(base: spec, mods: car.mods.compactMap(ModCatalog.mod))
                    VStack(alignment: .leading, spacing: Space.s4) {
                        Text(verbatim: car.nickname ?? car.fullLabel).typeStyle(.title).foregroundStyle(Color.chalk)
                        Readout(String(format: "%.1f", (est.quarterET.lowerBound + est.quarterET.upperBound) / 2), unit: "s", label: "EST. ¼ MILE")
                    }
                    SectionLabel("OPPONENT")
                    if let best { opponentRow(.ghost(best)) }
                    ForEach(houseCars, id: \.0) { opponentRow(.house($0.0, $0.1)) }
                    PrimaryButton("Stage") { running = true }.disabled(opponent == nil)
                    if !past.isEmpty { QuietButton("Past runs") { showPast = true } }
                } else if car != nil {
                    Text("This car needs power and weight before it can run. Add them in the Mod simulator.")
                        .typeStyle(.body).foregroundStyle(Color.dust)
                } else {
                    SkeletonRow()
                }
            }
            .padding(Space.margin)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("The Strip")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $running, onDismiss: { Task { await load() } }) {
            if let car, let spec, let opponent { RunView(env: env, car: car, spec: spec, opponent: opponent) }
        }
        .sheet(isPresented: $showPast) {
            Sheet(Text("Past runs")) {
                ScrollView {
                    ForEach(past) { r in
                        Row(Text(verbatim: String(format: "%.3f s", Double(r.etMs) / 1000)),
                            subtitle: Text(verbatim: r.createdAt.formatted(date: .abbreviated, time: .shortened)),
                            trailing: { Text(verbatim: String(format: "%.1f mph", Double(r.trapMphX10) / 10)).typeStyle(.readoutS) })
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task { await load() }
    }

    private func opponentRow(_ o: Opponent) -> some View {
        Button { opponent = o } label: {
            Row(Text(verbatim: o.title), trailing: {
                Image(systemName: opponent == o ? "largecircle.fill.circle" : "circle").foregroundStyle(opponent == o ? Color.sodium : Color.gravel)
            })
        }
        .buttonStyle(RowButtonStyle())
    }

    private func load() async {
        car = try? await env.garage.car(carID)
        var variant: CatalogVariant?
        if let id = car?.catalogVariantID { variant = try? await env.catalog.variant(id) }
        if let car { spec = VehicleSpec.from(variant: variant, car: car) }
        past = (try? await env.progress.raceResults(for: carID)) ?? []
        best = past.min { $0.etMs < $1.etMs }
        if opponent == nil { opponent = best.map(Opponent.ghost) ?? .house(houseCars[1].0, houseCars[1].1) }
    }
}

// MARK: G8 Run

@MainActor
@Observable
final class RaceModel {
    enum Phase: Equatable { case staging, tree(Int), racing, done, redLight }
    let car: Car
    let mods: [Mod]
    var me: RunState
    var them: RunState
    var phase: Phase = .staging
    var throttle = false
    var launched = false
    var tick = 0
    var greenTick: Int?
    var reactionMs = 0
    var log = InputLog(launchRpm: 0, launchTick: 0, shifts: [], lifts: [])
    @ObservationIgnored private var themLog: InputLog?
    @ObservationIgnored private var themLaunchTick = 0
    @ObservationIgnored private var pendingShift = false
    @ObservationIgnored private var liftStart: Int?
    @ObservationIgnored private var acc = 0.0
    @ObservationIgnored private var last: Date?
    @ObservationIgnored let synth = EngineSynth()
    static let dt = 1.0 / 240

    init(car: Car, spec: VehicleSpec, opponent: Opponent) {
        self.car = car
        mods = car.mods.compactMap(ModCatalog.mod)
        let mine = modified(spec, mods: mods, high: false)
        me = RunState(spec: mine, launchRpm: 1000)
        switch opponent {
        case let .ghost(r):
            themLog = InputLog.decode(r.inputLog)
            them = RunState(spec: mine, launchRpm: themLog?.launchRpm ?? 3500)
        case let .house(_, s):
            them = RunState(spec: s, launchRpm: min(s.redline * 0.55, 4500))
            themLaunchTick = 60 + Int.random(in: 0...20)
        }
        synth.apply(SoundProfile(layout: .from(cylinders: mine.cylinders, flat: mine.layout == .flat, crossPlane: mine.crankPlane == .cross,
                                               rotary: mine.layout == .rotary), redline: mine.redline))
    }

    func start() {
        synth.start()
        Task { [weak self] in
            while let self, self.phase != .done, self.phase != .redLight || !self.them.finished {
                self.frame(.now)
                try? await Task.sleep(for: .milliseconds(8))
                if self.phase == .redLight { break }
            }
        }
        Task {
            for i in 0...3 {
                try? await Task.sleep(for: .milliseconds(i == 0 ? 1500 : 500))
                if phase == .redLight { return }
                phase = i < 3 ? .tree(i) : .racing
            }
            greenTick = tick
        }
    }

    /// Left thumb: drop the clutch at green, then shift.
    func tapShift() {
        switch phase {
        case .staging, .tree:
            phase = .redLight
            synth.set(rpm: 900, load: 0)
        case .racing:
            if !launched {
                launched = true
                reactionMs = Int(Double(tick - (greenTick ?? tick)) * Self.dt * 1000)
                log.launchRpm = me.rpm
                log.launchTick = tick - (greenTick ?? tick)
                me = RunState(spec: me.spec, launchRpm: me.rpm)
            } else {
                pendingShift = true
            }
        default: break
        }
    }

    func setThrottle(_ on: Bool) {
        guard throttle != on else { return }
        throttle = on
        guard launched else { return }
        let rel = tick - (greenTick ?? 0)
        if on, let s = liftStart { log.lifts.append([s, rel]); liftStart = nil } else if !on { liftStart = rel }
    }

    /// Fixed 240 Hz steps, decoupled from the display rate.
    func frame(_ now: Date) {
        guard let last else { self.last = now; return }
        acc += min(0.1, now.timeIntervalSince(last))
        self.last = now
        while acc >= Self.dt {
            acc -= Self.dt
            step()
        }
    }

    private func step() {
        tick += 1
        let green = greenTick.map { tick - $0 }
        // Staged: throttle revs the engine against the clutch.
        if !launched {
            if phase != .redLight {
                let target = throttle ? me.spec.redline * 0.6 : 1000
                let rpm = me.rpm + (target - me.rpm) * 0.05
                me = RunState(spec: me.spec, launchRpm: rpm)
                synth.set(rpm: rpm, load: throttle ? 0.5 : 0)
            }
        } else if !me.finished {
            let shift = pendingShift
            pendingShift = false
            if shift, let g = green { log.shifts.append(g) }
            me.step(throttle: throttle ? 1 : 0, shift: shift, dt: Self.dt)
            synth.set(rpm: me.rpm, load: throttle ? 1 : 0.1)
        }
        // Opponent.
        if let g = green, !them.finished {
            if let l = themLog {
                if g >= l.launchTick {
                    let rel = g
                    let lifted = l.lifts.contains { rel >= $0[0] && rel < $0[1] }
                    them.step(throttle: lifted ? 0 : 1, shift: l.shifts.contains(rel), dt: Self.dt)
                }
            } else if g >= themLaunchTick {
                them.step(throttle: 1, shift: them.rpm >= them.spec.redline * 0.97, dt: Self.dt)
            }
        }
        if me.finished && (them.finished || phase == .done) && phase == .racing {
            phase = .done
            synth.set(rpm: 900, load: 0)
        }
    }

    var meResult: RunResult { me.result(reactionMs: reactionMs) }
    var themResult: RunResult { them.result(reactionMs: themLog == nil ? Int(Double(themLaunchTick) * Self.dt * 1000) : (themLog?.launchTick ?? 0) * 1000 / 240) }
}

struct RunView: View {
    let env: AppEnvironment
    @State private var model: RaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var thud = 0

    init(env: AppEnvironment, car: Car, spec: VehicleSpec, opponent: Opponent) {
        self.env = env
        _model = State(initialValue: RaceModel(car: car, spec: spec, opponent: opponent))
    }

    var body: some View {
        Group {
            if model.phase == .done || model.phase == .redLight {
                TimeSlip(model: model, again: { dismiss() }, close: { dismiss() })
            } else {
                scene.orientation(.landscape)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .haptic(.thud, trigger: thud)
        .onAppear { model.start() }
        .onDisappear { model.synth.stop() }
        .onChange(of: model.phase) {
            if model.phase == .done && !saved {
                saved = true
                let r = model.meResult
                Task {
                    guard let me = await env.auth.currentSession()?.userID else { return }
                    _ = try? await env.progress.saveRaceResult(RaceResult(
                        userID: me, carID: model.car.id, mods: model.car.mods, reactionMs: r.reactionMs, etMs: Int(r.quarterET * 1000),
                        trapMphX10: Int(r.quarterMph * 10), sixtyFtMs: Int(r.sixtyFt * 1000), inputLog: model.log.encoded()))
                }
            }
        }
    }

    private var scene: some View {
        Group {
            ZStack {
                Canvas { ctx, size in
                    let laneH = size.height * 0.18
                    let scale = size.width * 0.8 / 402.336
                    for (i, d) in [model.me.distance, model.them.distance].enumerated() {
                        let y = size.height * 0.35 + CGFloat(i) * laneH * 1.3
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: laneH)), with: .color(Color.tarmac))
                        let x = size.width * 0.08 + CGFloat(min(d, 402.336)) * scale
                        ctx.fill(Path(roundedRect: CGRect(x: x - 30, y: y + laneH * 0.25, width: 60, height: laneH * 0.5), cornerRadius: 6),
                                 with: .color(i == 0 ? Color.sodium : Color.dust))
                    }
                    ctx.fill(Path(CGRect(x: size.width * 0.08 + 402.336 * scale, y: size.height * 0.3, width: 3, height: laneH * 2.8)),
                             with: .color(Color.chalk))
                }
                VStack {
                    tree
                    Spacer()
                    HStack(alignment: .bottom) {
                        Button { model.tapShift(); thud += model.launched ? 0 : 1 } label: {
                            Text(model.launched ? "Shift" : "Launch").typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                                .frame(width: Size.row * 2, height: Size.row * 2)
                                .background(Color.chalk, in: Circle())
                        }
                        Spacer()
                        tach
                        Spacer()
                        Text("Throttle").typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                            .frame(width: Size.row * 2, height: Size.row * 2)
                            .background(model.throttle ? Color.go : Color.sodium, in: Circle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.setThrottle(true) }.onEnded { _ in model.setThrottle(false) })
                    }
                    .padding(Space.margin)
                }
            }
        }
    }

    private var tree: some View {
        HStack(spacing: Space.s8) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(lit(i) ? Color.sodium : Color.curb).frame(width: Space.s24, height: Space.s24)
            }
            Circle().fill(model.phase == .racing ? Color.go : Color.curb).frame(width: Space.s24, height: Space.s24)
        }
        .padding(Space.s12)
        .background(Color.tarmac, in: Capsule())
        .padding(.top, Space.s24)
    }

    private func lit(_ i: Int) -> Bool {
        if case let .tree(n) = model.phase { return i <= n }
        return false
    }

    private var tach: some View {
        let frac = model.me.rpm / model.me.spec.redline
        return VStack(spacing: Space.s4) {
            ZStack {
                Circle().trim(from: 0.15, to: 0.85).stroke(Color.curb, lineWidth: Space.s8).rotationEffect(.degrees(90))
                Circle().trim(from: 0.15, to: 0.15 + 0.7 * min(1, frac)).stroke(frac > 0.95 ? Color.brake : Color.sodium, lineWidth: Space.s8)
                    .rotationEffect(.degrees(90))
                Text(verbatim: "\(model.me.gear + 1)").typeStyle(.readoutL).foregroundStyle(Color.chalk)
            }
            .frame(width: Size.row * 2, height: Size.row * 2)
            Circle().fill(frac > 0.95 ? Color.brake : Color.curb).frame(width: Space.s12, height: Space.s12)
        }
    }
}

// MARK: G9 Time slip

struct TimeSlip: View {
    let model: RaceModel
    let again: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s16) {
                slip
                if let image = ImageRenderer(content: slip.frame(width: 340)).uiImage {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Virtual run · Waypoints", image: Image(uiImage: image))) {
                        Text("Share").typeStyle(.bodyStrong).foregroundStyle(Color.sodium)
                    }
                }
                PrimaryButton("Run again", action: again)
                SecondaryButton("Change opponent", action: close)
            }
            .padding(Space.margin)
        }
    }

    private var slip: some View {
        let a = model.meResult, b = model.themResult
        let red = model.phase == .redLight
        let won = !red && a.quarterET + Double(a.reactionMs) / 1000 <= b.quarterET + Double(b.reactionMs) / 1000
        return VStack(alignment: .leading, spacing: Space.s4) {
            Text("VIRTUAL RUN · WAYPOINTS").typeStyle(.readoutS)
            Text(verbatim: model.car.fullLabel).typeStyle(.readoutM)
            line("", "YOU", "OPP")
            line("R/T", red ? "RED" : String(format: "%.3f", Double(a.reactionMs) / 1000), String(format: "%.3f", Double(b.reactionMs) / 1000))
            line("60 FT", String(format: "%.3f", a.sixtyFt), String(format: "%.3f", b.sixtyFt))
            line("⅛ ET", String(format: "%.3f", a.eighthET), String(format: "%.3f", b.eighthET))
            line("⅛ MPH", String(format: "%.2f", a.eighthMph), String(format: "%.2f", b.eighthMph))
            line("¼ ET", String(format: "%.3f", a.quarterET), String(format: "%.3f", b.quarterET))
            line("¼ MPH", String(format: "%.2f", a.quarterMph), String(format: "%.2f", b.quarterMph))
            Text(red ? "RED LIGHT" : (won ? "WIN · YOU" : "WIN · OPPONENT")).typeStyle(.readoutM).padding(.top, Space.s8)
        }
        .foregroundStyle(Color.asphalt)
        .padding(Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chalk)
    }

    private func line(_ k: String, _ a: String, _ b: String) -> some View {
        HStack {
            Text(verbatim: k).frame(width: 70, alignment: .leading)
            Text(verbatim: a).frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: b).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .typeStyle(.readoutM)
    }
}
