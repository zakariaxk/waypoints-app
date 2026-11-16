import Core
import DesignSystem
import EngineAudio
import PerformanceModel
import SwiftUI
import VehicleCatalog

/// The Strip (plan 10.8 G7–G9, 11.4): a virtual quarter mile driven by the same model as the
/// estimates. No GPS, real speed, or location is read here.
public enum RaceFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.race, presentation: .push(tab: .garage)) { route in
            guard case let .race(id) = route else { return nil }
            return AnyView(Lobby(env: env, carID: id))
        }
        registry.registerDebugScreen("car-of-week") { AnyView(DebugCarOfWeek(env: env)) }
        registry.registerDebugScreen("timeslip") { AnyView(DebugTimeSlip(env: env)) }
    }
}

#if DEBUG
/// `waypoints://debug/timeslip`: a completed slip including the car-of-week line — the slip is
/// unreachable headless otherwise (L37). Runs the model to .done with near-redline shifts.
private struct DebugTimeSlip: View {
    let env: AppEnvironment
    @State private var model: RaceModel?

    var body: some View {
        ZStack {
            Color.asphalt.ignoresSafeArea()
            if let model { TimeSlip(model: model, weekly: true, again: {}, close: {}) } else { ProgressView() }
        }
        .preferredColorScheme(.dark)
        .task {
            guard let me = await env.auth.currentSession()?.userID,
                  let cars = try? await env.garage.cars(of: me), let car = cars.first else { return }
            var spec: VehicleSpec?
            for c in cars {
                var variant: CatalogVariant?
                if let id = c.catalogVariantID { variant = try? await env.catalog.variant(id) }
                if let s = VehicleSpec.from(variant: variant, car: c) { spec = s; break }
            }
            // Seed garages can lack specs; a house car's spec fills in so the slip still renders.
            guard let spec = spec ?? Ladder.cars.first?.spec else { return }
            let m = RaceModel(car: car, spec: spec, opponent: .house(Ladder.cars[0]), tree: .sportsman)
            m.phase = .racing
            m.greenTick = 0
            m.launched = true
            m.reactionMs = 120
            m.log.launchTick = 0
            m.log.launchRpm = m.me.spec.redline * 0.6
            m.throttle = true
            var t = Date()
            for _ in 0..<240 * 60 where m.phase != .done {
                if !m.me.finished, m.me.rpm >= m.me.spec.redline * 0.97 { m.tapShift() }
                t += 1.0 / 60
                m.frame(t)
            }
            model = m
        }
    }
}
#endif

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
    case friend(name: String, RaceResult, VehicleSpec)
    case house(HouseCar)
    /// Any catalog car, stock or with chosen mods, driven by the model (STR-10).
    case bench(BenchCar)

    var title: String {
        switch self {
        case .ghost: String(localized: "Your best run", bundle: .module)
        case let .friend(name, r, _): String(localized: "\(name)'s run · \(Format.number(Double(r.etMs) / 1000, fractionDigits: 2)) s", bundle: .module)
        case let .house(h): h.title
        case let .bench(b): b.title
        }
    }

    var subtitle: String? {
        switch self {
        case let .house(h): h.specLine
        case let .bench(b): HouseCar(rung: 0, spec: b.spec).specLine
        default: nil
        }
    }
}

// MARK: G7 Lobby

struct Lobby: View {
    let env: AppEnvironment
    let carID: CarID
    @State private var car: Car?
    @State private var spec: VehicleSpec?
    @State private var best: RaceResult?
    @State private var past: [RaceResult] = []
    @State private var opponent: Opponent?
    @State private var friendRuns: [Opponent] = []
    @State private var running = false
    @State private var showPast = false
    @State private var bench: BenchCar?
    @State private var pickingBench = false
    @State private var failed = false
    /// MOD-15: the car's saved builds; "" keys the current mods.
    @State private var builds: [SavedBuild] = []
    @State private var buildKey = ""
    @AppStorage(Ladder.openedKey) private var opened = 0
    @AppStorage(Ladder.treeKey) private var tree = TreeKind.sportsman

    /// The build picked to run, if any.
    private var build: SavedBuild? { builds.first { $0.id.uuidString == buildKey } }
    /// The car as it will run: the picked build's mods replace the car's own.
    private func withBuild(_ c: Car) -> Car {
        guard let build else { return c }
        var copy = c
        copy.mods = build.mods
        return copy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Virtual drag strip. A game, not a challenge. Keep it off the street.", bundle: .module)
                    .typeStyle(.body).foregroundStyle(Color.chalk)
                    .padding(.horizontal, Space.margin)
                if let car, let spec {
                    let est = estimate(base: spec, mods: (build?.mods ?? car.mods).compactMap(ModCatalog.mod))
                    VStack(alignment: .leading, spacing: Space.s12) {
                        Text(verbatim: car.nickname ?? car.fullLabel).typeStyle(.title).foregroundStyle(Color.chalk)
                        Readout(Format.number((est.quarterET.lowerBound + est.quarterET.upperBound) / 2, fractionDigits: 1), unit: "s", label: "EST. ¼ MILE",
                                token: .readoutL,
                                range: .init(low: est.quarterET.lowerBound, high: est.quarterET.upperBound, bounds: 8...18))
                            .frame(maxWidth: Size.row * 3, alignment: .leading)
                        if !builds.isEmpty { buildMenu }
                    }
                    .padding(Space.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r20, style: .continuous))
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.s16)
                    CarOfWeekSection(env: env)
                    SectionLabel("OPPONENT")
                    if let best { opponentRow(.ghost(best)) }
                    ForEach(friendRuns, id: \.self) { opponentRow($0) }
                    if let bench { opponentRow(.bench(bench)) }
                    Button { pickingBench = true } label: {
                        Row(bench == nil ? Text("Pick any car", bundle: .module) : Text("Pick another car", bundle: .module),
                            subtitle: Text("Bench race any car in the catalog, stock or with mods.", bundle: .module),
                            showsDivider: false, trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                    SectionLabel("LADDER")
                    ForEach(Ladder.cars.prefix(openRung + 1)) { opponentRow(.house($0)) }
                    Group {
                        if openRung + 1 < Ladder.cars.count {
                            Text("Beat house car \(openRung + 1) to open house car \(openRung + 2).", bundle: .module)
                        } else {
                            Text("All ten house cars are open.", bundle: .module)
                        }
                    }
                    .typeStyle(.foot).foregroundStyle(Color.dust)
                    .padding(.horizontal, Space.margin)
                    .padding(.top, Space.s8)
                    SectionLabel("TREE")
                    VStack(alignment: .leading, spacing: Space.s8) {
                        SegmentedSwitch(selection: $tree, options: [(value: TreeKind.sportsman, title: "Sportsman"),
                                                                   (value: TreeKind.pro, title: "Pro")])
                        Text(verbatim: tree.detail).typeStyle(.foot).foregroundStyle(Color.dust)
                        PrimaryButton("Stage") { running = true }.disabled(opponent == nil)
                            .padding(.top, Space.s24)
                        if !past.isEmpty { QuietButton("Past runs") { showPast = true }.frame(maxWidth: .infinity) }
                    }
                    .padding(.horizontal, Space.margin)
                } else if car != nil {
                    Text("This car needs power and weight before it can run. Add them in the Mod simulator.", bundle: .module)
                        .typeStyle(.body).foregroundStyle(Color.dust)
                        .padding(Space.margin)
                } else if failed {
                    ErrorState(Text("Couldn't load this car. Check your connection and try again.", bundle: .module)) {
                        Task { await load() }
                    }
                    .padding(.top, Space.s48)
                } else {
                    SkeletonRow()
                }
            }
            .padding(.top, Space.s16)
            .padding(.bottom, Space.s32)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("The Strip")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $running, onDismiss: { Task { await load() } }) {
            if let car, let spec, let opponent { RunView(env: env, car: withBuild(car), spec: spec, opponent: opponent, tree: tree) }
        }
        .sheet(isPresented: $pickingBench) {
            BenchPicker(env: env) { b in
                bench = b
                opponent = .bench(b)
                pickingBench = false
            }
        }
        .sheet(isPresented: $showPast) {
            Sheet(Text("Past runs", bundle: .module)) {
                ScrollView {
                    ForEach(past) { r in
                        // Trap stays in mph everywhere: it is the drag strip's unit, as on a real time slip (SET-3).
                        Row(Text(verbatim: Format.number(Double(r.etMs) / 1000, fractionDigits: 3) + " s"),
                            subtitle: Text(verbatim: r.createdAt.formatted(date: .abbreviated, time: .shortened)),
                            trailing: { Text(verbatim: Format.number(Double(r.trapMphX10) / 10, fractionDigits: 1) + " mph").typeStyle(.readoutS) })
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task { await load() }
    }

    private var openRung: Int { max(0, min(opened, Ladder.cars.count - 1)) }

    /// MOD-15: run the car's current mods or one of its saved builds.
    private var buildMenu: some View {
        Menu {
            Picker(selection: $buildKey) {
                Text("Current mods", bundle: .module).tag("")
                ForEach(builds) { b in Text(verbatim: b.name).tag(b.id.uuidString) }
            } label: {
                Text("Build", bundle: .module)
            }
        } label: {
            Row(Text("Build", bundle: .module),
                subtitle: Text(verbatim: build?.name ?? String(localized: "Current mods", bundle: .module)),
                showsDivider: false, trailing: { Disclosure() })
        }
    }

    private func opponentRow(_ o: Opponent) -> some View {
        Button { opponent = o } label: {
            Row(Text(verbatim: o.title), subtitle: o.subtitle.map { Text(verbatim: $0) }, trailing: {
                Image(systemName: opponent == o ? "largecircle.fill.circle" : "circle").foregroundStyle(opponent == o ? Color.sodium : Color.gravel)
                    .accessibilityHidden(true)
            })
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityAddTraits(opponent == o ? .isSelected : [])
    }

    private func load() async {
        car = try? await env.garage.car(carID)
        failed = car == nil
        var variant: CatalogVariant?
        if let id = car?.catalogVariantID { variant = try? await env.catalog.variant(id) }
        if let car { spec = VehicleSpec.from(variant: variant, car: car) }
        past = (try? await env.progress.raceResults(for: carID)) ?? []
        // A ghost replays its input log through the model; under another model version the same
        // inputs give different times, so only runs from this version are offered.
        best = past.filter { $0.modelVersion == PerformanceModelVersion.current }.min { $0.etMs < $1.etMs }
        if opponent == nil { opponent = best.map(Opponent.ghost) ?? .house(Ladder.cars[openRung]) }
        if case .ghost? = opponent { opponent = best.map(Opponent.ghost) ?? .house(Ladder.cars[openRung]) }
        var runs: [Opponent] = []
        for f in ((try? await env.friends.friends()) ?? []).prefix(10) {
            guard let r = try? await env.progress.raceResults(by: f.id, limit: 10)
                    .first(where: { $0.modelVersion == PerformanceModelVersion.current }),
                  let theirCar = try? await env.garage.car(r.carID) else { continue }
            var v: CatalogVariant?
            if let id = theirCar.catalogVariantID { v = try? await env.catalog.variant(id) }
            if let s = VehicleSpec.from(variant: v, car: theirCar) {
                runs.append(.friend(name: f.profile.displayName, r, modified(s, mods: r.mods.compactMap(ModCatalog.mod), high: false)))
            }
        }
        friendRuns = runs
        builds = (try? await env.garage.savedBuilds(for: carID)) ?? []
        if !buildKey.isEmpty, builds.allSatisfy({ $0.id.uuidString != buildKey }) { buildKey = "" }
    }
}

// MARK: G8 Run

@MainActor
@Observable
final class RaceModel {
    enum Phase: Equatable { case staging, tree(Int), racing, done, redLight }
    let car: Car
    let mods: [Mod]
    let tree: TreeKind
    /// The ladder rung being raced, when the opponent is a house car.
    let houseRung: Int?
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
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored let synth = EngineSynth()
    static let dt = 1.0 / 240

    init(car: Car, spec: VehicleSpec, opponent: Opponent, tree: TreeKind) {
        self.car = car
        self.tree = tree
        if case let .house(h) = opponent { houseRung = h.rung } else { houseRung = nil }
        mods = car.mods.compactMap(ModCatalog.mod)
        let mine = modified(spec, mods: mods, high: false)
        me = RunState(spec: mine, launchRpm: 1000)
        switch opponent {
        case let .ghost(r):
            themLog = InputLog.decode(r.inputLog)
            them = RunState(spec: modified(spec, mods: r.mods.compactMap(ModCatalog.mod), high: false), launchRpm: themLog?.launchRpm ?? 3500)
        case let .friend(_, r, s):
            themLog = InputLog.decode(r.inputLog)
            them = RunState(spec: s, launchRpm: themLog?.launchRpm ?? 3500)
        case let .house(h):
            let s = h.spec
            them = RunState(spec: s, launchRpm: min(s.redline * 0.55, 4500))
            themLaunchTick = 60 + Int.random(in: 0...20)
        case let .bench(b):
            let s = modified(b.spec, mods: b.mods.compactMap(ModCatalog.mod), high: false)
            them = RunState(spec: s, launchRpm: min(s.redline * 0.55, 4500))
            themLaunchTick = 60 + Int.random(in: 0...20)
        }
        synth.apply(SoundProfile(layout: .from(cylinders: mine.cylinders, flat: mine.layout == .flat, crossPlane: mine.crankPlane == .cross,
                                               rotary: mine.layout == .rotary), redline: mine.redline))
    }

    func start() {
        guard tasks.isEmpty else { return }
        synth.start()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled, let self, self.phase != .done, self.phase != .redLight || !self.them.finished {
                self.frame(.now)
                try? await Task.sleep(for: .milliseconds(8))
                if self.phase == .redLight { break }
            }
        })
        tasks.append(Task { [weak self] in
            guard let tree = self?.tree else { return }
            for step in tree.sequence {
                try? await Task.sleep(for: .milliseconds(step.ms))
                guard let self else { return }
                while self.paused, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
                guard !Task.isCancelled, self.phase != .redLight else { return }
                self.phase = step.lit > 3 ? .racing : .tree(step.lit - 1)
                if step.lit > 3 { self.greenTick = self.tick }
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        synth.stop()
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
                liftStart = throttle ? nil : log.launchTick
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
    var paused = false

    func frame(_ now: Date) {
        if paused { last = nil; return }
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
                if g > l.launchTick {
                    let rel = g
                    let lifted = l.lifts.contains { $0.count == 2 && rel > $0[0] && rel <= $0[1] }
                    them.step(throttle: lifted ? 0 : 1, shift: l.shifts.contains(rel), dt: Self.dt)
                }
            } else if g >= themLaunchTick {
                them.step(throttle: 1, shift: them.rpm >= them.spec.redline * 0.97, dt: Self.dt)
            }
        }
        if me.finished && (them.finished || phase == .done) && phase == .racing {
            if let s = liftStart, let g = green { log.lifts.append([s, g]); liftStart = nil }
            phase = .done
            synth.set(rpm: 900, load: 0)
        }
    }

    var meResult: RunResult { me.result(reactionMs: reactionMs) }

    /// Your lane reached the finish first, counting reaction time, without a red light.
    var won: Bool {
        guard phase == .done else { return false }
        let a = meResult, b = themResult
        return a.quarterET + Double(a.reactionMs) / 1000 <= b.quarterET + Double(b.reactionMs) / 1000
    }
    var themResult: RunResult { them.result(reactionMs: themLog == nil ? Int(Double(themLaunchTick) * Self.dt * 1000) : (themLog?.launchTick ?? 0) * 1000 / 240) }
}

struct RunView: View {
    let env: AppEnvironment
    /// STR-11: a car-of-the-week run saves to the weekly board, not `race_results`.
    let weekly: Bool
    @State private var model: RaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var thud = 0
    @State private var setup: (Car, VehicleSpec, Opponent, TreeKind)
    @State private var run = 0
    @AppStorage(Ladder.openedKey) private var opened = 0

    init(env: AppEnvironment, car: Car, spec: VehicleSpec, opponent: Opponent, tree: TreeKind, weekly: Bool = false) {
        self.env = env
        self.weekly = weekly
        _model = State(initialValue: RaceModel(car: car, spec: spec, opponent: opponent, tree: tree))
        _setup = State(initialValue: (car, spec, opponent, tree))
    }

    var body: some View {
        Group {
            if model.phase == .done || model.phase == .redLight {
                TimeSlip(model: model, weekly: weekly, again: { restart() }, close: { dismiss() })
            } else {
                scene.orientation(.landscape)
                    .background { TwoFingerTap { model.paused = true; model.synth.setMuted(true) } }
                    .overlay {
                        if model.paused {
                            VStack(spacing: Space.s12) {
                                PrimaryButton("Resume") { model.paused = false; model.synth.setMuted(false) }
                                SecondaryButton("Restart") { restart() }
                                QuietButton("Quit") { dismiss() }
                            }
                            .frame(maxWidth: Size.row * 5)
                            .padding(Space.s24)
                            .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r20))
                        }
                    }
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .haptic(.thud, trigger: thud)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.phase) {
            if model.phase == .done && !saved && model.me.quarter != nil {
                saved = true
                if model.won, let rung = model.houseRung, rung >= opened, rung + 1 < Ladder.cars.count { opened = rung + 1 }
                let r = model.meResult
                Task {
                    if weekly {
                        try? await env.progress.saveCarOfWeekRun(etMs: Int(r.quarterET * 1000),
                            trapMphX10: Int(r.quarterMph * 10), reactionMs: r.reactionMs,
                            modelVersion: PerformanceModelVersion.current)
                    } else {
                        guard let me = await env.auth.currentSession()?.userID else { return }
                        _ = try? await env.progress.saveRaceResult(RaceResult(
                            userID: me, carID: model.car.id, mods: model.car.mods, reactionMs: r.reactionMs, etMs: Int(r.quarterET * 1000),
                            trapMphX10: Int(r.quarterMph * 10), sixtyFtMs: Int(r.sixtyFt * 1000), inputLog: model.log.encoded(),
                            modelVersion: PerformanceModelVersion.current))
                    }
                }
            }
        }
    }

    private func restart() {
        model.stop()
        model = RaceModel(car: setup.0, spec: setup.1, opponent: setup.2, tree: setup.3)
        saved = false
        model.start()
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
                        // The car is drawn at its lane's proportions: half the lane tall, twice that long.
                        let carH = laneH * 0.5, carW = carH * 2
                        ctx.fill(Path(roundedRect: CGRect(x: x - carW / 2, y: y + laneH * 0.25, width: carW, height: carH),
                                      cornerRadius: Radius.r6),
                                 with: .color(i == 0 ? Color.sodium : Color.dust))
                    }
                    ctx.fill(Path(CGRect(x: size.width * 0.08 + 402.336 * scale, y: size.height * 0.3, width: Size.paintBar,
                                         height: laneH * 2.8)),
                             with: .color(Color.chalk))
                }
                VStack {
                    tree
                    Spacer()
                    HStack(alignment: .bottom) {
                        Button { let launching = model.phase == .racing && !model.launched; model.tapShift(); thud += launching ? 1 : 0 } label: {
                            (model.launched ? Text("Shift", bundle: .module) : Text("Launch", bundle: .module))
                                .typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                                .minimumScaleFactor(0.5)
                                .frame(width: Size.row * 2, height: Size.row * 2)
                                .background(Color.chalk, in: Circle())
                        }
                        Spacer()
                        tach
                        Spacer()
                        Text("Throttle", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                            .minimumScaleFactor(0.5)
                            .frame(width: Size.row * 2, height: Size.row * 2)
                            .background(model.throttle ? Color.go : Color.sodium, in: Circle())
                            .contentShape(Circle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in model.setThrottle(true) }.onEnded { _ in model.setThrottle(false) })
                            // VoiceOver can't hold: a double tap toggles the throttle on and off.
                            .accessibilityElement()
                            .accessibilityLabel(Text("Throttle", bundle: .module))
                            .accessibilityValue(model.throttle ? Text("On", bundle: .module) : Text("Off", bundle: .module))
                            .accessibilityAddTraits(model.throttle ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { model.setThrottle(!model.throttle) }
                    }
                    .padding(Space.margin)
                }
            }
        }
        .accessibilityAction(named: Text("Throttle", bundle: .module)) { model.setThrottle(!model.throttle) }
        .accessibilityAction(named: Text("Shift", bundle: .module)) {
            let launching = model.phase == .racing && !model.launched
            model.tapShift(); thud += launching ? 1 : 0
        }
    }

    private var tree: some View {
        VStack(spacing: Space.s4) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(lit(i) ? Color.sodium : Color.curb).frame(width: Space.s20, height: Space.s20)
            }
            Circle().fill(model.phase == .racing ? Color.go : Color.curb).frame(width: Space.s20, height: Space.s20)
        }
        .padding(Space.s8)
        .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.r12, style: .continuous).strokeBorder(Color.seam, lineWidth: Size.Marker.innerStroke))
        .padding(.top, Space.s8)
        .accessibilityElement()
        .accessibilityLabel(Text("Tree", bundle: .module))
        .accessibilityValue(treeValue)
    }

    private var treeValue: Text {
        switch model.phase {
        case .staging: Text("Staged", bundle: .module)
        case let .tree(n): Text("\(n + 1) of 3 lit", bundle: .module)
        case .racing: Text("Green", bundle: .module)
        case .redLight: Text("Red light", bundle: .module)
        case .done: Text("Finished", bundle: .module)
        }
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
            Circle().fill(frac > 0.95 ? Color.brake : Color.curb).frame(width: Space.s20, height: Space.s20)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Gear \(model.me.gear + 1)", bundle: .module))
        .accessibilityValue(frac > 0.95 ? Text("\(Int(model.me.rpm)) rpm, shift now", bundle: .module)
                            : Text("\(Int(model.me.rpm)) rpm", bundle: .module))
    }
}

// MARK: G9 Time slip

struct TimeSlip: View {
    let model: RaceModel
    /// STR-11: marks the slip "Car of the week"; awards nothing.
    let weekly: Bool
    let again: () -> Void
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s16) {
                slip.frame(maxWidth: Size.row * 6)
                if model.won, let rung = model.houseRung {
                    (rung + 1 < Ladder.cars.count ? Text("House car \(rung + 2) is open.", bundle: .module)
                     : Text("That was the top of the ladder.", bundle: .module))
                        .typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                PrimaryButton("Run again", action: again)
                if weekly {
                    SecondaryButton("Done", action: close)
                } else {
                    SecondaryButton("Change opponent", action: close)
                }
                if let image = ImageRenderer(content: slip.frame(width: Size.row * 6)).uiImage {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview("Virtual run · Waypoints", image: Image(uiImage: image))) {
                        Text("Share", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.sodium)
                            .frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget)
                            .contentShape(Rectangle())
                    }
                }
            }
            .padding(Space.margin)
        }
    }

    /// Speeds on the slip are mph whatever the locale: the strip's own convention (SET-3).
    private var slip: some View {
        let a = model.meResult, b = model.themResult
        let red = model.phase == .redLight
        let won = !red && model.won
        return VStack(alignment: .leading, spacing: Space.s4) {
            Text("VIRTUAL RUN · WAYPOINTS", bundle: .module).typeStyle(.readoutS)
            Text(verbatim: model.car.fullLabel).typeStyle(.readoutM)
            if weekly { Text("Car of the week", bundle: .module).typeStyle(.readoutS) }
            rule
            line("", String(localized: "YOU", bundle: .module), String(localized: "OPP", bundle: .module))
            line("R/T", red ? String(localized: "RED", bundle: .module) : Format.number(Double(a.reactionMs) / 1000, fractionDigits: 3),
                 Format.number(Double(b.reactionMs) / 1000, fractionDigits: 3))
            line("60 FT", Format.number(a.sixtyFt, fractionDigits: 3), Format.number(b.sixtyFt, fractionDigits: 3))
            line("⅛ ET", Format.number(a.eighthET, fractionDigits: 3), Format.number(b.eighthET, fractionDigits: 3))
            line("⅛ MPH", Format.number(a.eighthMph, fractionDigits: 2), Format.number(b.eighthMph, fractionDigits: 2))
            line("¼ ET", Format.number(a.quarterET, fractionDigits: 3), Format.number(b.quarterET, fractionDigits: 3))
            line("¼ MPH", Format.number(a.quarterMph, fractionDigits: 2), Format.number(b.quarterMph, fractionDigits: 2))
            rule
            (red ? Text("RED LIGHT", bundle: .module) : won ? Text("WIN · YOU", bundle: .module) : Text("WIN · OPPONENT", bundle: .module))
                .typeStyle(.readoutM)
        }
        .foregroundStyle(Color.asphalt)
        .padding(Space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chalk)
    }

    /// The dashed rule a slip printer draws between blocks.
    private var rule: some View {
        Rectangle().fill(.clear).frame(height: Size.Chart.stock)
            .overlay {
                GeometryReader { geo in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                        p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .stroke(Color.asphalt, style: StrokeStyle(lineWidth: Size.Chart.stock, dash: Size.Chart.stockDash))
                }
            }
            .padding(.vertical, Space.s4)
            .accessibilityHidden(true)
    }

    private func line(_ k: String, _ a: String, _ b: String) -> some View {
        HStack(spacing: Space.s8) {
            Text(verbatim: k).frame(width: Size.row + Space.s16, alignment: .leading)
            Text(verbatim: a).frame(maxWidth: .infinity, alignment: .trailing)
            Text(verbatim: b).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .typeStyle(.readoutM)
        .lineLimit(1)
    }
}

/// Two-finger tap, which SwiftUI has no gesture for.
struct TwoFingerTap: UIViewRepresentable {
    let action: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let g = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.fire))
        g.numberOfTouchesRequired = 2
        g.cancelsTouchesInView = false
        v.addGestureRecognizer(g)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.action = action }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

