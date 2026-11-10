import Core
import Foundation

public enum ModCategory: String, Sendable, Hashable, CaseIterable, Codable {
    case intake, exhaust, tune, forcedInduction = "forced_induction", fuel, weight

    public var label: String {
        switch self {
        case .intake: "INTAKE"
        case .exhaust: "EXHAUST"
        case .tune: "TUNE"
        case .forcedInduction: "FORCED INDUCTION"
        case .fuel: "FUEL"
        case .weight: "WEIGHT"
        }
    }
}

/// A = independent dyno ("measured"), B = manufacturer ("claimed"), C = rule of thumb ("typical").
public enum Confidence: String, Sendable, Hashable, Codable {
    case a = "A", b = "B", c = "C"
    public var label: String { switch self { case .a: "measured"; case .b: "claimed"; case .c: "typical" } }
}

/// How a mod changes the synthesized sound (plan 11.3).
public struct SoundDelta: Sendable, Hashable, Codable {
    public var gainDb: Double = 0
    public var cutoffScale: Double = 1
    public var removesResonator = false
    public var brightness: Double = 0
    public var reflection: Double = 0
    public var crackle = false
    public var whine = false
    public var whistle = false
    public init(gainDb: Double = 0, cutoffScale: Double = 1, removesResonator: Bool = false, brightness: Double = 0,
                reflection: Double = 0, crackle: Bool = false, whine: Bool = false, whistle: Bool = false) {
        self.gainDb = gainDb; self.cutoffScale = cutoffScale; self.removesResonator = removesResonator
        self.brightness = brightness; self.reflection = reflection; self.crackle = crackle; self.whine = whine
        self.whistle = whistle
    }
}

public struct Mod: Sendable, Hashable, Identifiable {
    public let id: String
    public var category: ModCategory
    public var name: String
    public var brand: String?
    /// `nil` applies to every aspiration.
    public var aspirations: Set<Aspiration>?
    /// Platform ids such as "s650_gt"; empty means generic.
    public var platforms: [String]
    public var hpGainPct: ClosedRange<Double>
    public var tqGainPct: ClosedRange<Double>
    public var absolute: (hp: Double, tq: Double)?
    public var requires: [String]
    public var requiresTune: Bool
    public var conflicts: [String]
    public var weightDeltaLb: Double
    public var sound: SoundDelta
    public var confidence: Confidence
    public var sourceURL: String

    public static func == (a: Mod, b: Mod) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }

    func applies(to spec: VehicleSpec) -> Bool {
        aspirations.map { $0.contains(spec.aspiration) } ?? true
    }

    /// "+10 to +18 hp" on a given base power.
    public func rangeText(base: Double) -> String {
        if let abs = absolute { return "\(Int(abs.hp)) hp" }
        if category == .weight { return "\(Int(weightDeltaLb)) lb" }
        let lo = Int((base * hpGainPct.lowerBound / 100).rounded()), hi = Int((base * hpGainPct.upperBound / 100).rounded())
        return lo == hi ? "+\(hi) hp" : "+\(lo) to +\(hi) hp"
    }
}

/// The bundled mod catalog (plan 11.2). Generic gains are confidence C; kits carry their
/// manufacturer figures (B).
public enum ModCatalog {
    static let na: Set<Aspiration> = [.natural]
    static let boosted: Set<Aspiration> = [.turbo, .twinCharged]
    static let tuneSrc = "https://www.dynojet.com/"

    static func m(_ id: String, _ cat: ModCategory, _ name: String, _ asp: Set<Aspiration>? = nil, hp: ClosedRange<Double>,
                  tq: ClosedRange<Double>? = nil, requires: [String] = [], tune: Bool = false, conflicts: [String] = [],
                  sound: SoundDelta = .init(), weight: Double = 0, conf: Confidence = .c, src: String = tuneSrc,
                  brand: String? = nil, platforms: [String] = [], absolute: (Double, Double)? = nil) -> Mod {
        Mod(id: id, category: cat, name: name, brand: brand, aspirations: asp, platforms: platforms, hpGainPct: hp,
            tqGainPct: tq ?? hp, absolute: absolute.map { (hp: $0.0, tq: $0.1) }, requires: requires, requiresTune: tune,
            conflicts: conflicts, weightDeltaLb: weight, sound: sound, confidence: conf, sourceURL: src)
    }

    public static let all: [Mod] = [
        // Intake
        m("intake_cai_na", .intake, "Cold air intake", na, hp: 0...2, sound: .init(gainDb: 1, brightness: 0.1),
          src: "https://www.motortrend.com/how-to/cold-air-intake-dyno-test/"),
        m("intake_cai_turbo", .intake, "Cold air intake", boosted, hp: 1...3, sound: .init(gainDb: 1, whistle: true),
          src: "https://www.motortrend.com/how-to/cold-air-intake-dyno-test/"),
        m("intake_manifold", .intake, "Intake manifold", na, hp: 2...4, tune: true),
        m("throttle_body", .intake, "Big throttle body", hp: 0...1.5),
        m("intercooler", .intake, "Front-mount intercooler", boosted, hp: 1...4),
        m("charge_pipe", .intake, "Charge pipe", boosted, hp: 0...1),
        m("turbo_inlet", .intake, "Turbo inlet", boosted, hp: 1...2, sound: .init(whistle: true)),
        // Exhaust
        m("catback", .exhaust, "Cat-back exhaust", hp: 0...3, sound: .init(gainDb: 3, cutoffScale: 1.3),
          src: "https://www.hotrod.com/how-to/exhaust-dyno-test/"),
        m("axleback", .exhaust, "Axle-back exhaust", hp: 0...1, sound: .init(gainDb: 2, cutoffScale: 1.15)),
        m("muffler_delete", .exhaust, "Muffler delete", hp: 0...2, conflicts: ["catback", "axleback"],
          sound: .init(gainDb: 8, cutoffScale: 1.8)),
        m("resonator_delete", .exhaust, "Resonator delete", hp: 0...1, sound: .init(gainDb: 2, removesResonator: true)),
        m("headers_lt", .exhaust, "Long-tube headers", na, hp: 4...7, tune: true, sound: .init(gainDb: 2, brightness: 0.3, reflection: 0.2),
          src: "https://www.hotrod.com/how-to/long-tube-headers-dyno/"),
        m("headers_shorty", .exhaust, "Shorty headers", na, hp: 1...3, sound: .init(brightness: 0.15)),
        m("hiflow_cats", .exhaust, "High-flow cats", hp: 1...3, sound: .init(gainDb: 1, brightness: 0.2)),
        m("downpipe", .exhaust, "Downpipe", boosted, hp: 3...8, tune: true, sound: .init(gainDb: 2, brightness: 0.2, whistle: true)),
        m("straight_pipe", .exhaust, "Straight pipe", hp: 1...4, conflicts: ["catback", "muffler_delete", "axleback"],
          sound: .init(gainDb: 12, cutoffScale: 2.5, removesResonator: true, brightness: 0.4, reflection: 0.5)),
        m("x_pipe", .exhaust, "X-pipe", na, hp: 0...2, sound: .init(brightness: 0.15)),
        m("h_pipe", .exhaust, "H-pipe", na, hp: 0...2, sound: .init(gainDb: 1)),
        // Tune
        m("tune_s1_na", .tune, "Stage 1 tune", na, hp: 2...5, sound: .init(crackle: false), src: "https://www.cobbtuning.com/"),
        m("tune_s1_turbo", .tune, "Stage 1 tune", boosted, hp: 15...30, src: "https://www.cobbtuning.com/"),
        m("tune_s2_turbo", .tune, "Stage 2 tune (bolt-ons)", boosted, hp: 25...40, requires: ["downpipe", "intake_cai_turbo"],
          conflicts: ["tune_s1_turbo"], src: "https://www.cobbtuning.com/"),
        m("tune_burble", .tune, "Pops and burble map", hp: 0...0, sound: .init(crackle: true)),
        m("tune_custom_na", .tune, "Custom dyno tune", na, hp: 3...6, conflicts: ["tune_s1_na"]),
        // Fuel
        m("e85_na", .fuel, "E85 (with tune)", na, hp: 3...5, requires: ["tune_s1_na"]),
        m("e85_turbo", .fuel, "E85 (with tune)", boosted, hp: 10...20, requires: ["tune_s1_turbo"]),
        m("e30_turbo", .fuel, "E30 blend", boosted, hp: 4...8, tune: true),
        m("fuel_pump", .fuel, "Fuel pump upgrade", hp: 0...0),
        m("injectors", .fuel, "Larger injectors", hp: 0...1, tune: true),
        // Forced induction (generic)
        m("turbo_upgrade", .forcedInduction, "Upgraded turbo", boosted, hp: 15...35, tune: true, sound: .init(whistle: true)),
        m("sc_centrifugal", .forcedInduction, "Centrifugal supercharger kit", na, hp: 35...55, tune: true,
          sound: .init(whine: true), weight: 40),
        m("sc_roots", .forcedInduction, "Roots supercharger kit", na, hp: 40...60, tune: true, sound: .init(whine: true), weight: 55),
        m("turbo_kit_na", .forcedInduction, "Turbo kit", na, hp: 40...70, tune: true, sound: .init(whistle: true), weight: 45),
        // Platform kits (B: manufacturer crank figures, 93 octane)
        m("s650_whipple_fp", .forcedInduction, "Ford Performance supercharger", na, hp: 0...0, sound: .init(whine: true), weight: 50,
          conf: .b, src: "https://performanceparts.ford.com/", brand: "Ford Performance / Whipple", platforms: ["s650_gt"],
          absolute: (750, 615)),
        m("s650_whipple_s1", .forcedInduction, "Whipple Gen 6 3.0 L Stage 1", na, hp: 0...0, sound: .init(whine: true), weight: 55,
          conf: .b, src: "https://whipplesuperchargers.com/", brand: "Whipple", platforms: ["s650_gt"], absolute: (810, 640)),
        m("s650_whipple_s2", .forcedInduction, "Whipple Stage 2", na, hp: 0...0, sound: .init(whine: true), weight: 55,
          conf: .b, src: "https://whipplesuperchargers.com/", brand: "Whipple", platforms: ["s650_gt"], absolute: (875, 660)),
        m("s650_roush_p2", .forcedInduction, "Roush Phase 2 (TVS R2650)", na, hp: 0...0, sound: .init(whine: true), weight: 60,
          conf: .b, src: "https://roushperformance.com/", brand: "Roush", platforms: ["s650_gt"], absolute: (810, 630)),
        // Weight
        m("wheels_light", .weight, "Lightweight wheels", hp: 0...0, weight: -30),
        m("seats_bucket", .weight, "Bucket seats", hp: 0...0, weight: -40),
        m("battery_light", .weight, "Lightweight battery", hp: 0...0, weight: -20),
        m("rear_delete", .weight, "Rear seat delete", hp: 0...0, weight: -35),
        m("carbon_hood", .weight, "Carbon hood", hp: 0...0, weight: -15),
        m("exhaust_ti", .weight, "Titanium exhaust", hp: 0...1, sound: .init(gainDb: 3, brightness: 0.3), weight: -20),
    ]

    public static func mod(_ id: String) -> Mod? { all.first { $0.id == id } }

    /// Mods that can go on this car: aspiration matches, and platform kits only on their platform.
    public static func available(for spec: VehicleSpec, platform: String?) -> [Mod] {
        all.filter { m in
            m.applies(to: spec) && (m.platforms.isEmpty || platform.map(m.platforms.contains) == true)
        }
    }

    /// A platform id for kit matching.
    public static func platform(for car: Car) -> String? {
        if car.make == "Ford" && car.model == "Mustang" && car.year >= 2024 && (car.trim ?? "").contains("GT") { return "s650_gt" }
        return nil
    }
}
