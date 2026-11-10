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
        registry.registerRoute(.modSim) { route in
            guard case let .modSim(id) = route else { return nil }
            return AnyView(ModSimView(env: env, carID: id))
        }
    }
}

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
    @ObservationIgnored let synth = EngineSynth()
    @ObservationIgnored private var revTask: Task<Void, Never>?

    init(env: AppEnvironment, carID: CarID) { self.env = env; self.carID = carID }

    var selected: [Mod] { mods.compactMap(ModCatalog.mod) }
    var stockEstimate: Estimate? { stock.map { estimate(base: $0, mods: []) } }
    var modEstimate: Estimate? { stock.map { estimate(base: $0, mods: selected) } }

    var available: [Mod] {
        guard let stock, let car else { return [] }
        return ModCatalog.available(for: stock, platform: ModCatalog.platform(for: car))
    }

    func load() async {
        car = try? await env.garage.car(carID)
        if let id = car?.catalogVariantID { variant = try? await env.catalog.variant(id) }
        if let car {
            stock = VehicleSpec.from(variant: variant, car: car)
            mods = Set(car.mods)
            saved = mods
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
        car = (try? await env.garage.updateCar(c)) ?? c
        stock = VehicleSpec.from(variant: variant, car: car!)
        applySound()
    }

    func toggle(_ m: Mod) {
        if mods.contains(m.id) {
            mods.remove(m.id)
        } else {
            mods.subtract(m.conflicts)
            for other in mods.compactMap(ModCatalog.mod) where other.conflicts.contains(m.id) { mods.remove(other.id) }
            mods.insert(m.id)
            let tuned = selected.contains { $0.category == .tune }
            if m.requiresTune && !tuned { prompt = m }
            for r in m.requires where !mods.contains(r) { prompt = m }
        }
        applySound()
    }

    func addTune(for m: Mod) {
        let tune = available.first { $0.category == .tune && $0.id.hasPrefix("tune_s1") }
        if m.requiresTune, let tune { mods.insert(tune.id) }
        for r in m.requires { mods.insert(r) }
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
            self?.revTask = nil
        }
    }

    func save(addToTimeline: Bool) async {
        guard var c = car else { return }
        let added = mods.subtracting(saved)
        c.mods = Array(mods).sorted()
        car = (try? await env.garage.updateCar(c)) ?? c
        saved = mods
        if addToTimeline {
            for id in added {
                guard let m = ModCatalog.mod(id) else { continue }
                _ = try? await env.garage.addBuildEntry(BuildEntry(carID: carID, happenedOn: .now, title: m.name, modID: id))
            }
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

    init(env: AppEnvironment, carID: CarID) { _model = State(initialValue: ModSimModel(env: env, carID: carID)) }

    var body: some View {
        ScrollView {
            if !model.loaded {
                SkeletonBlock(height: Size.row * 4).padding(Space.margin)
            } else if model.stock == nil {
                specsForm
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    chart
                    readouts
                    Text("Estimates. Real results depend on the tune, the dyno, and the day.")
                        .typeStyle(.foot).foregroundStyle(Color.dust).padding(.horizontal, Space.margin)
                    soundControls
                    modList
                }
                .padding(.bottom, Space.s48)
            }
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle(model.car?.title ?? "Mod simulator")
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
        .confirmationDialog(model.prompt.map { "\($0.name) needs a tune" } ?? "", isPresented: Binding(
            get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } })) {
            if let m = model.prompt { Button("Add Stage 1 tune too") { model.addTune(for: m) } }
            Button("Not now", role: .cancel) {}
        }
        .haptic(.tick, trigger: tick)
        .task { await model.load() }
        .onDisappear { model.synth.stop() }
    }

    private var specsForm: some View {
        VStack(alignment: .leading, spacing: Space.s16) {
            Text("We don't have specs for this car. Enter power and weight to simulate it.").typeStyle(.body).foregroundStyle(Color.chalk)
            Field("Horsepower", text: $hp).keyboardType(.numberPad)
            Field("Weight (lb)", text: $weight).keyboardType(.numberPad)
            Field("Torque (lb-ft)", text: $torque).keyboardType(.numberPad)
            Field("Redline", text: $redline).keyboardType(.numberPad)
            PrimaryButton("Enter specs") {
                guard let h = Int(hp), let w = Int(weight) else { return }
                Task { await model.useSpecs(hp: h, weight: w, torque: Int(torque) ?? Int(Double(h) * 0.9), redline: Int(redline) ?? 6500) }
            }
            .disabled(Int(hp) == nil || Int(weight) == nil)
        }
        .padding(Space.margin)
    }

    private var chart: some View {
        let stockCurve = model.stockEstimate?.curve ?? []
        let modCurve = model.modEstimate?.curve ?? []
        return Chart {
            ForEach(stockCurve, id: \.rpm) { p in
                LineMark(x: .value("rpm", p.rpm), y: .value("hp", p.hp), series: .value("s", "stock hp")).foregroundStyle(Color.dust)
                LineMark(x: .value("rpm", p.rpm), y: .value("tq", p.torque), series: .value("s", "stock tq")).foregroundStyle(Color.dust)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(modCurve, id: \.rpm) { p in
                LineMark(x: .value("rpm", p.rpm), y: .value("hp", p.hp), series: .value("s", "hp")).foregroundStyle(Color.sodium)
                LineMark(x: .value("rpm", p.rpm), y: .value("tq", p.torque), series: .value("s", "tq")).foregroundStyle(Color.sodium)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
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
        .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Color.dust) } }
        .chartYAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Color.dust); AxisGridLine().foregroundStyle(Color.seam) } }
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
            }
        }
        .frame(height: Size.row * 4)
        .padding(Space.margin)
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

    private var soundControls: some View {
        VStack(alignment: .leading, spacing: Space.s12) {
            Text("Hold to rev").typeStyle(.bodyStrong).foregroundStyle(Color.asphalt)
                .frame(maxWidth: .infinity, minHeight: Size.row * 1.6)
                .background(Color.sodium, in: RoundedRectangle(cornerRadius: Radius.r20))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !revving { revving = true; model.rev(true) } }
                    .onEnded { _ in revving = false; model.rev(false) })
                .opacity(model.soundOn ? 1 : Opacity.inactive)
                .accessibilityAddTraits(.isButton)
            Text(verbatim: "\(Int(model.revRpm)) rpm").typeStyle(.readoutM).foregroundStyle(Color.chalk)
            Row(Text("Synthesized sound"), showsDivider: false, trailing: {
                Toggle("", isOn: Binding(get: { model.soundOn }, set: { model.setSound($0) })).labelsHidden().tint(.sodium)
            })
        }
        .padding(Space.margin)
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
