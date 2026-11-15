import Charts
import Core
import DesignSystem
import EngineAudio
import PerformanceModel
import SwiftUI

/// G6 Mod simulator (plan 10.8, 11.2, 11.3). Route `modSim`; turns on G3's readout row.
public enum ModSimFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.modSim, presentation: .push(tab: .garage)) { route in
            guard case let .modSim(id) = route else { return nil }
            return AnyView(ModSimView(env: env, carID: id))
        }
        #if DEBUG
        registry.registerDebugScreen("modsim-builds") { AnyView(DebugBuilds(env: env)) }
        #endif
    }
}

#if DEBUG
/// `waypoints://debug/modsim-builds`: G6 on my first car with its first two saved builds overlaid.
private struct DebugBuilds: View {
    let env: AppEnvironment
    @State private var carID: CarID?

    var body: some View {
        NavigationStack {
            if let carID { ModSimView(env: env, carID: carID, comparing: true) } else { Color.asphalt.ignoresSafeArea() }
        }
        .task {
            guard let me = await env.auth.currentSession()?.userID else { return }
            carID = (try? await env.garage.cars(of: me))?.first?.id
        }
    }
}
#endif

extension SoundProfile {
    /// The synthesizer profile for a spec with mods.
    static func from(_ spec: VehicleSpec, mods: [Mod]) -> SoundProfile {
        var p = SoundProfile(layout: .from(cylinders: spec.cylinders, flat: spec.layout == .flat,
                                           crossPlane: spec.crankPlane == .cross, rotary: spec.layout == .rotary),
                             redline: spec.redline, whistle: spec.aspiration == .turbo || spec.aspiration == .twinCharged)
        if spec.aspiration == .supercharged { p.whine = true }
        for m in mods {
            let s = m.sound
            p.gainDb += s.gainDb
            p.cutoffScale *= s.cutoffScale
            p.brightness += s.brightness
            p.reflection += s.reflection
            if s.removesResonator { p.resonator = false }
            p.crackle = p.crackle || s.crackle
            p.whine = p.whine || s.whine
            p.whistle = (p.whistle || s.whistle) && !s.whine
        }
        p.gainDb = min(p.gainDb, 14)
        return p
    }
}

@MainActor
@Observable
final class ModSimModel {
    let env: AppEnvironment
    let carID: CarID
    var car: Car?
    var variant: CatalogVariant?
    var stock: VehicleSpec?
    var mods: Set<String> = []
    var saved: Set<String> = []
    var scrubRpm: Double?
    var revRpm: Double = 900
    var soundOn = true
    var loaded = false
    var prompt: Mod?
    var failed = false
    var toast: ToastMessage?
    /// MOD-15: the car's saved builds, and the one or two picked to overlay on the chart.
    var builds: [SavedBuild] = []
    var buildsFailed = false
    var own = false
    var compare: [UUID] = []
    @ObservationIgnored let synth = EngineSynth()
    @ObservationIgnored private var revTask: Task<Void, Never>?
    @ObservationIgnored private let comparing: Bool

    init(env: AppEnvironment, carID: CarID, comparing: Bool = false) {
        self.env = env; self.carID = carID; self.comparing = comparing
    }

    var selected: [Mod] { mods.compactMap(ModCatalog.mod) }
    var stockEstimate: Estimate? { stock.map { estimate(base: $0, mods: []) } }
    var modEstimate: Estimate? { stock.map { estimate(base: $0, mods: selected) } }

    /// What the chart overlays: two saved builds, or the current selection against one. Empty when nothing is picked.
    var compared: [(name: String, estimate: Estimate)] {
        guard let stock, let current = modEstimate else { return [] }
        let picked = compare.compactMap { id in builds.first { $0.id == id } }
            .map { (name: $0.name, estimate: estimate(base: stock, mods: $0.mods.compactMap(ModCatalog.mod))) }
        if picked.count == 1 { return [(name: String(localized: "Current selection", bundle: .module), estimate: current)] + picked }
        return picked
    }

    func loadBuilds() async {
        do {
            builds = try await env.garage.savedBuilds(for: carID)
            buildsFailed = false
            if comparing && compare.isEmpty { compare = builds.prefix(2).map(\.id) }
        } catch { buildsFailed = true }
    }

    private func store(_ next: [SavedBuild]) async -> Bool {
        do {
            try await env.garage.setSavedBuilds(next, for: carID)
            builds = next
            compare.removeAll { id in !next.contains { $0.id == id } }
            return true
        } catch {
            toast = ToastMessage(Text("Couldn't save to the car. Check your connection and try again.", bundle: .module))
            return false
        }
    }

    /// Saves the mods switched on now as a new build, or renames `renaming`.
    func saveBuild(named name: String, renaming: SavedBuild?) async {
        var next = builds
        if let i = next.firstIndex(where: { $0.id == renaming?.id }) {
            next[i].name = name
        } else if next.count < SavedBuild.limit {
            next.append(SavedBuild(name: name, mods: mods.sorted()))
        } else { return }
        if await store(next) { toast = ToastMessage(Text("Build saved", bundle: .module)) }
    }

    func deleteBuild(_ b: SavedBuild) async {
        let before = builds
        if await store(before.filter { $0.id != b.id }) {
            toast = ToastMessage(Text("Build deleted", bundle: .module)) { [weak self] in
                Task { _ = await self?.store(before) }
            }
        }
    }

    func loadBuild(_ b: SavedBuild) {
        mods = Set(b.mods).intersection(available.map(\.id))
        applySound()
        toast = ToastMessage(Text("Loaded \(b.name)", bundle: .module))
    }

    func toggleCompare(_ b: SavedBuild) {
        if let i = compare.firstIndex(of: b.id) { compare.remove(at: i) } else {
            if compare.count == 2 { compare.removeFirst() }
            compare.append(b.id)
        }
    }

    var available: [Mod] {
        guard let stock, let car else { return [] }
        return ModCatalog.available(for: stock, platform: ModCatalog.platform(for: car, variant: variant))
    }

    func load() async {
        car = try? await env.garage.car(carID)
        failed = car == nil
        if let id = car?.catalogVariantID { variant = try? await env.catalog.variant(id) }
        if let car {
            stock = VehicleSpec.from(variant: variant, car: car)
            mods = stock == nil ? Set(car.mods) : Set(car.mods).intersection(available.map(\.id))
            saved = mods
            own = await env.auth.currentSession()?.userID == car.ownerID
            await loadBuilds()
        }
        loaded = true
        applySound()
    }

    func useSpecs(hp: Int, weight: Int, torque: Int, redline: Int) async {
        guard var c = car else { return }
        c.specOverrides.hp = hp
        c.specOverrides.weightLb = weight
        c.specOverrides.torqueLbFt = torque
        c.specOverrides.redline = redline
        do { car = try await env.garage.updateCar(c) } catch {
            car = c
            toast = ToastMessage(Text("Couldn't save to the car. Check your connection and try again.", bundle: .module))
        }
        stock = VehicleSpec.from(variant: variant, car: car ?? c)
        mods.formIntersection(available.map(\.id))
        applySound()
    }

    func toggle(_ m: Mod) {
        if mods.contains(m.id) {
            mods.remove(m.id)
        } else {
            mods.subtract(m.conflicts)
            // One forced-induction system at a time.
            if m.category == .forcedInduction {
                for other in selected where other.category == .forcedInduction { mods.remove(other.id) }
            }
            for other in mods.compactMap(ModCatalog.mod) where other.conflicts.contains(m.id) { mods.remove(other.id) }
            mods.insert(m.id)
            let tuned = selected.contains { $0.category == .tune }
            if m.requiresTune && !tuned { prompt = m }
            if !missing(for: m).isEmpty { prompt = m }
        }
        applySound()
    }

    func missing(for m: Mod) -> [Mod] {
        let tuned = selected.contains { $0.category == .tune }
        return m.requires.filter { !mods.contains($0) }.compactMap(ModCatalog.mod).filter { $0.category != .tune || !tuned }
    }

    func addTune(for m: Mod) {
        let tuned = selected.contains { $0.category == .tune }
        let tune = available.first { $0.category == .tune && $0.id.hasPrefix("tune_s1") }
        let needed = missing(for: m)
        if m.requiresTune, !tuned, let tune { mods.insert(tune.id) }
        for r in needed { mods.insert(r.id) }
        applySound()
    }

    func applySound() {
        guard let stock else { return }
        synth.apply(.from(modified(stock, mods: selected, high: false), mods: selected))
    }

    func setSound(_ on: Bool) {
        soundOn = on
        if !on { synth.stop() }
    }

    func scrub(_ rpm: Double?) {
        scrubRpm = rpm
        guard soundOn else { return }
        if let rpm {
            if !synth.isRunning { synth.start(); applySound() }
            synth.set(rpm: rpm, load: 0.7)
        } else if revTask == nil {
            synth.set(rpm: 900, load: 0)
        }
    }

    /// Hold to rev: sweep up through first gear; release lets it fall.
    func rev(_ down: Bool) {
        guard let stock else { return }
        if down && soundOn && !synth.isRunning { synth.start(); applySound() }
        revTask?.cancel()
        revTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let target = down ? stock.redline * 0.98 : 900
                let rate = down ? 2600.0 : -3400.0
                self.revRpm = down ? min(target, self.revRpm + rate / 60) : max(target, self.revRpm + rate / 60)
                self.synth.set(rpm: self.revRpm, load: down ? 1 : 0)
                if !down && self.revRpm <= 900 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            if !Task.isCancelled { self?.revTask = nil }
        }
    }

    func save(addToTimeline: Bool) async {
        guard var c = car else { return }
        let added = mods.subtracting(saved)
        c.mods = Array(mods).sorted()
        do {
            car = try await env.garage.updateCar(c)
            saved = mods
            if addToTimeline {
                for id in added {
                    guard let m = ModCatalog.mod(id) else { continue }
                    try await env.garage.addBuildEntry(BuildEntry(carID: carID, happenedOn: .now, title: m.name, modID: id))
                }
            }
            toast = ToastMessage(Text("Saved to car", bundle: .module))
        } catch {
            toast = ToastMessage(Text("Couldn't save to the car. Check your connection and try again.", bundle: .module))
        }
    }
}

struct ModSimView: View {
    @State private var model: ModSimModel
    @State private var tick = 0
    @State private var revving = false
    @State private var askSave = false
    @State private var hp = ""
    @State private var weight = ""
    @State private var torque = ""
    @State private var redline = "6500"
    @State private var askName = false
    @State private var renaming: SavedBuild?
    @State private var buildName = ""

    init(env: AppEnvironment, carID: CarID, comparing: Bool = false) {
        _model = State(initialValue: ModSimModel(env: env, carID: carID, comparing: comparing))
    }

    var body: some View {
        ScrollView {
            if !model.loaded {
                SkeletonBlock(height: Size.row * 4).padding(Space.margin)
            } else if model.failed {
                ErrorState(Text("Couldn't load this car. Check your connection and try again.", bundle: .module)) {
                    Task { await model.load() }
                }
                .padding(.top, Space.s48)
            } else if model.stock == nil {
                specsForm
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    chart
                    legend.padding(.horizontal, Space.margin).padding(.bottom, Space.s16)
                    if model.compared.isEmpty { readouts } else { comparison }
                    Text("Estimates. Real results depend on the tune, the dyno, and the day.", bundle: .module)
                        .typeStyle(.foot).foregroundStyle(Color.dust).padding(.horizontal, Space.margin)
                    buildList
                    soundControls
                    modList
                    #if DEBUG
                    NavigationLink { ReferenceCarsView() } label: {
                        Row(Text(verbatim: "Reference cars"), subtitle: Text(verbatim: "Debug: model beside published tests"),
                            trailing: { Disclosure() })
                    }
                    .buttonStyle(RowButtonStyle())
                    #endif
                }
                .padding(.bottom, Space.s48)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(model.car.map { $0.nickname ?? $0.shortLabel } ?? "Mod simulator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.stock != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    QuietButton("Save to car") { askSave = true }.disabled(model.mods == model.saved)
                }
            }
        }
        .confirmationDialog("Save to car", isPresented: $askSave) {
            Button("Save") { Task { await model.save(addToTimeline: false) } }
            Button("Save and add to timeline") { Task { await model.save(addToTimeline: true) } }
        }
        .confirmationDialog(promptTitle, isPresented: Binding(
            get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } })) {
            if let m = model.prompt {
                let names = model.missing(for: m).map(\.name)
                if names.count > 1 {
                    Button("Add them too") { model.addTune(for: m) }
                } else if let name = names.first {
                    Button("Add \(name) too") { model.addTune(for: m) }
                } else {
                    Button("Add Stage 1 tune too") { model.addTune(for: m) }
                }
            }
            Button("Not now", role: .cancel) {}
        }
        .alert(Text(renaming == nil ? "Save build" : "Rename build", bundle: .module), isPresented: $askName) {
            TextField("Build name", text: $buildName)
            Button("Save") {
                let name = String(buildName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(SavedBuild.nameLimit))
                guard !name.isEmpty else { return }
                Task { await model.saveBuild(named: name, renaming: renaming) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .haptic(.tick, trigger: tick)
        .toast(Binding(get: { model.toast }, set: { model.toast = $0 }))
        .task { await model.load() }
        .onDisappear {
            revving = false
            model.rev(false)
            model.synth.stop()
        }
    }

    private var promptTitle: String {
        guard let m = model.prompt else { return "" }
        let names = model.missing(for: m).map(\.name)
        return names.isEmpty ? String(localized: "\(m.name) needs a tune", bundle: .module)
            : String(localized: "\(m.name) needs \(names.formatted(.list(type: .and)))", bundle: .module)
    }

    static var metric: Bool { Locale.current.measurementSystem == .metric }

    private var specsForm: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("We don't have specs for this car. Enter power and weight to simulate it.", bundle: .module).typeStyle(.body).foregroundStyle(Color.chalk)
            Field("Horsepower", text: $hp).keyboardType(.numberPad)
            Field(Self.metric ? "Weight (kg)" : "Weight (lb)", text: $weight).keyboardType(.numberPad)
            Field("Torque (lb-ft)", text: $torque).keyboardType(.numberPad)
            Field("Redline", text: $redline).keyboardType(.numberPad)
            PrimaryButton("Enter specs") {
                guard let h = Int(hp), let entered = Int(weight), h > 0, entered > 0 else { return }
                // Stored in pounds; entered in the locale's unit (SET-3).
                let w = Self.metric ? Int((Double(entered) * 2.20462).rounded()) : entered
                Task { await model.useSpecs(hp: h, weight: w, torque: Int(torque) ?? Int(Double(h) * 0.9), redline: Int(redline) ?? 6500) }
            }
            .disabled((Int(hp) ?? 0) <= 0 || (Int(weight) ?? 0) <= 0)
        }
        .padding(Space.margin)
    }

    private var chart: some View {
        let stockCurve = model.stockEstimate?.curve ?? []
        let overlay = model.compared
        let modCurve = overlay.first?.estimate.curve ?? model.modEstimate?.curve ?? []
        let secondCurve = overlay.count > 1 ? overlay[1].estimate.curve : []
        return Chart {
            ForEach(stockCurve, id: \.rpm) { p in
                LineMark(x: .value("rpm", p.rpm), y: .value("hp", p.hp), series: .value("s", "stock hp")).foregroundStyle(Color.dust)
                LineMark(x: .value("rpm", p.rpm), y: .value("tq", p.torque), series: .value("s", "stock tq")).foregroundStyle(Color.dust)
                    .lineStyle(StrokeStyle(lineWidth: Size.Chart.stock, dash: Size.Chart.stockDash))
            }
            ForEach(modCurve, id: \.rpm) { p in
                LineMark(x: .value("rpm", p.rpm), y: .value("hp", p.hp), series: .value("s", "hp")).foregroundStyle(Color.sodium)
                LineMark(x: .value("rpm", p.rpm), y: .value("tq", p.torque), series: .value("s", "tq")).foregroundStyle(Color.sodium)
                    .lineStyle(StrokeStyle(lineWidth: Size.Chart.modded, dash: Size.Chart.moddedDash))
            }
            ForEach(secondCurve, id: \.rpm) { p in
                LineMark(x: .value("rpm", p.rpm), y: .value("hp", p.hp), series: .value("s", "hp b")).foregroundStyle(Color.xenon)
                LineMark(x: .value("rpm", p.rpm), y: .value("tq", p.torque), series: .value("s", "tq b")).foregroundStyle(Color.xenon)
                    .lineStyle(StrokeStyle(lineWidth: Size.Chart.modded, dash: Size.Chart.moddedDash))
            }
            if let rpm = model.scrubRpm {
                RuleMark(x: .value("rpm", rpm)).foregroundStyle(Color.chalk)
                    .annotation(position: .top) {
                        if let p = modCurve.min(by: { abs($0.rpm - rpm) < abs($1.rpm - rpm) }) {
                            Text(verbatim: "\(Int(rpm)) rpm · \(Int(p.hp)) hp · \(Int(p.torque)) lb-ft").typeStyle(.readoutS)
                                .foregroundStyle(Color.chalk).padding(Space.s4).background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r6))
                        }
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis { AxisMarks { _ in AxisValueLabel().font(TypeToken.readoutS.font).foregroundStyle(Color.dust) } }
        .chartYAxis {
            AxisMarks { _ in
                AxisValueLabel().font(TypeToken.readoutS.font).foregroundStyle(Color.dust)
                AxisGridLine().foregroundStyle(Color.seam)
            }
        }
        .chartXAxisLabel(position: .bottom, alignment: .trailing) {
            Text("rpm", bundle: .module).typeStyle(.readoutS).foregroundStyle(Color.dust)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if let plot = proxy.plotFrame, let rpm: Double = proxy.value(atX: v.location.x - geo[plot].origin.x) {
                                let r = max(1000, min(model.stock?.redline ?? 7000, rpm))
                                if Int(r / 500) != Int((model.scrubRpm ?? 0) / 500) { tick += 1 }
                                model.scrub(r)
                            }
                        }
                        .onEnded { _ in model.scrub(nil) })
                    // VoiceOver: swipe up and down to step the scrub line 500 rpm at a time.
                    .accessibilityElement()
                    .accessibilityLabel(Text("Dyno curve", bundle: .module))
                    .accessibilityValue(scrubValue)
                    .accessibilityAdjustableAction { direction in
                        let top = model.stock?.redline ?? 7000
                        let now = model.scrubRpm ?? 1000
                        let next = direction == .increment ? now + 500 : direction == .decrement ? now - 500 : now
                        tick += 1
                        model.scrub(max(1000, min(top, next)))
                    }
            }
        }
        .frame(height: Size.row * 5)
        .padding(Space.margin)
    }

    /// Solid is power, dashed is torque; `dust` is stock, `sodium` is with the mods switched on.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s16) { legendLines; legendColors }
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s16) { legendLines }
                HStack(spacing: Space.s16) { legendColors }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var legendLines: some View {
        legendKey(Text("Power, hp", bundle: .module), color: .chalk, dash: [])
        legendKey(Text("Torque, lb-ft", bundle: .module), color: .chalk, dash: Size.Chart.moddedDash)
    }

    @ViewBuilder private var legendColors: some View {
        legendKey(Text("Stock", bundle: .module), color: .dust, dash: [])
        // While builds are overlaid, the comparison columns name the sodium and xenon lines.
        if model.compare.isEmpty { legendKey(Text("With mods", bundle: .module), color: .sodium, dash: []) }
    }

    private func legendKey(_ title: Text, color: Color, dash: [CGFloat]) -> some View {
        HStack(spacing: Space.s4) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: Size.Chart.modded / 2))
                p.addLine(to: CGPoint(x: Space.s20, y: Size.Chart.modded / 2))
            }
            .stroke(color, style: StrokeStyle(lineWidth: Size.Chart.modded, dash: dash))
            .frame(width: Space.s20, height: Size.Chart.modded)
            title.typeStyle(.foot).foregroundStyle(Color.dust).lineLimit(1).fixedSize()
        }
    }

    private var scrubValue: Text {
        guard let rpm = model.scrubRpm, let p = (model.modEstimate?.curve ?? []).min(by: { abs($0.rpm - rpm) < abs($1.rpm - rpm) }) else {
            return Text("Adjust to read power at an rpm", bundle: .module)
        }
        return Text("\(Int(rpm)) rpm, \(Int(p.hp)) horsepower, \(Int(p.torque)) pound-feet", bundle: .module)
    }

    private var readouts: some View {
        HStack(alignment: .top, spacing: Space.s12) {
            if let s = model.stockEstimate, let m = model.modEstimate {
                readout(m.hp, s.hp, "EST. HP", fmt: "%.0f", bounds: 0...1200, higherBetter: true)
                readout(m.torque, s.torque, "EST. TQ", fmt: "%.0f", bounds: 0...1000, higherBetter: true)
                readout(m.zeroToSixty, s.zeroToSixty, "0–60", fmt: "%.1f", unit: "s", bounds: 2...12, higherBetter: false)
                readout(m.quarterET, s.quarterET, "¼ MILE", fmt: "%.1f", unit: "s", bounds: 8...18, higherBetter: false)
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s8)
    }

    private func readout(_ r: ClosedRange<Double>, _ stock: ClosedRange<Double>, _ label: LocalizedStringKey, fmt: String,
                         unit: String? = nil, bounds: ClosedRange<Double>, higherBetter: Bool) -> some View {
        let mid = (r.lowerBound + r.upperBound) / 2, smid = (stock.lowerBound + stock.upperBound) / 2
        let delta = mid - smid
        return VStack(alignment: .leading, spacing: Space.s2) {
            Readout(String(format: fmt, mid), unit: unit, label: label, range: .init(low: r.lowerBound, high: r.upperBound, bounds: bounds))
            if abs(delta) >= 0.05 {
                Text(verbatim: (delta > 0 ? "+" : "") + String(format: fmt, delta)).typeStyle(.readoutS)
                    .foregroundStyle((delta > 0) == higherBetter ? Color.go : Color.brake)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// MOD-15: the two overlaid sets side by side, each estimate with its range and its change from stock.
    private var comparison: some View {
        HStack(alignment: .top, spacing: Space.s16) {
            if let s = model.stockEstimate {
                ForEach(Array(model.compared.enumerated()), id: \.offset) { i, c in
                    VStack(alignment: .leading, spacing: Space.s12) {
                        Text(verbatim: c.name).typeStyle(.sub).foregroundStyle(i == 0 ? Color.sodium : Color.xenon).lineLimit(1)
                        HStack(alignment: .top, spacing: Space.s12) {
                            readout(c.estimate.hp, s.hp, "EST. HP", fmt: "%.0f", bounds: 0...1200, higherBetter: true)
                            readout(c.estimate.torque, s.torque, "EST. TQ", fmt: "%.0f", bounds: 0...1000, higherBetter: true)
                        }
                        HStack(alignment: .top, spacing: Space.s12) {
                            readout(c.estimate.zeroToSixty, s.zeroToSixty, "0–60", fmt: "%.1f", unit: "s", bounds: 2...12, higherBetter: false)
                            readout(c.estimate.quarterET, s.quarterET, "¼ MILE", fmt: "%.1f", unit: "s", bounds: 8...18, higherBetter: false)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, Space.margin)
        .padding(.bottom, Space.s8)
    }

    private var buildList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("SAVED BUILDS")
            if model.buildsFailed {
                ErrorState(Text("Couldn't load saved builds. Check your connection and try again.", bundle: .module)) {
                    Task { await model.loadBuilds() }
                }
            } else {
                if model.builds.isEmpty {
                    Text(model.own ? "No saved builds yet. Save the mods switched on now as a build, then compare builds on the chart."
                         : "No saved builds on this car.", bundle: .module)
                        .typeStyle(.sub).foregroundStyle(Color.dust).padding(.horizontal, Space.margin)
                }
                ForEach(model.builds) { b in
                    let names = b.mods.compactMap(ModCatalog.mod).map(\.name)
                    Row(Text(verbatim: b.name),
                        subtitle: names.isEmpty ? Text("Stock", bundle: .module) : Text(verbatim: names.formatted(.list(type: .and))),
                        trailing: {
                            HStack(spacing: Space.s8) {
                                Chip("Compare", isSelected: model.compare.contains(b.id)) { model.toggleCompare(b) }
                                Menu {
                                    Button("Load") { model.loadBuild(b) }
                                    if model.own {
                                        Button("Rename") { renaming = b; buildName = b.name; askName = true }
                                        Button("Delete", role: .destructive) { Task { await model.deleteBuild(b) } }
                                    }
                                } label: { Image.symbol(Symbol.more).frame(minWidth: Size.hitTarget, minHeight: Size.hitTarget) }
                                .accessibilityLabel(Text("More options", bundle: .module))
                            }
                        })
                }
                if model.own && model.builds.count < SavedBuild.limit {
                    QuietButton("Save current as a build") { renaming = nil; buildName = ""; askName = true }
                        .padding(.horizontal, Space.margin)
                }
            }
        }
    }

    private var soundControls: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Hold to rev", bundle: .module).typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                .frame(maxWidth: .infinity, minHeight: Size.row * 1.5)
                .background(Color.sodium, in: RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radius.r12, style: .continuous))
                .scaleEffect(revving ? Opacity.pressedScale : 1)
                .motion(.quick, value: revving)
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !revving { revving = true; model.rev(true) } }
                    .onEnded { _ in revving = false; model.rev(false) })
                .opacity(model.soundOn ? 1 : Opacity.inactive)
                .accessibilityElement()
                .accessibilityLabel(Text("Rev", bundle: .module))
                .accessibilityValue(revving ? Text("Revving", bundle: .module) : Text("Idle", bundle: .module))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    revving.toggle()
                    model.rev(revving)
                }
                .padding(.horizontal, Space.margin)
            Readout(String(Int(model.revRpm)), unit: "rpm", token: .readoutL)
                .padding(.horizontal, Space.margin)
            Row(Text("Synthesized sound", bundle: .module), showsDivider: false, trailing: {
                Toggle(isOn: Binding(get: { model.soundOn }, set: { model.setSound($0) })) {
                    Text("Synthesized sound", bundle: .module)
                }
                .labelsHidden().tint(.sodium)
            })
        }
        .padding(.top, Space.s24)
    }

    private var modList: some View {
        let base = model.stock?.hpCrank ?? 300
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(ModCategory.allCases, id: \.self) { cat in
                let list = model.available.filter { $0.category == cat }
                if !list.isEmpty {
                    SectionLabel(verbatim: cat.label)
                    ForEach(list, id: \.id) { m in
                        let tuned = model.selected.contains { $0.category == .tune }
                        Row(Text(verbatim: m.name),
                            subtitle: Text(verbatim: m.requiresTune && !tuned ? "Needs a tune · \(m.rangeText(base: base))" : m.rangeText(base: base)),
                            trailing: {
                                HStack(spacing: Space.s8) {
                                    Text(verbatim: m.confidence.label).typeStyle(.foot).foregroundStyle(Color.gravel)
                                    Toggle("", isOn: Binding(get: { model.mods.contains(m.id) }, set: { _ in
                                        tick += 1
                                        model.toggle(m)
                                    })).labelsHidden().tint(.sodium)
                                }
                            })
                    }
                }
            }
        }
    }
}
