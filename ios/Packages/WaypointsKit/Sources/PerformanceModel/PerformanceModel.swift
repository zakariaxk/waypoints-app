import Core
import Foundation

// Plan 11.2. Pure, deterministic, synchronous, Sendable. No UI, no I/O.

public enum EngineLayout: String, Sendable, Hashable, Codable { case inline, v, flat, rotary }
public enum CrankPlane: String, Sendable, Hashable, Codable { case cross, flat }

public struct VehicleSpec: Sendable, Hashable {
    public var hpCrank: Double
    public var torqueLbFt: Double
    public var weightLb: Double
    public var drivetrain: Drivetrain
    public var aspiration: Aspiration
    public var redline: Double
    public var gearRatios: [Double]
    public var finalDrive: Double
    public var tireRadiusM: Double
    public var cdA: Double
    public var cylinders: Int
    public var layout: EngineLayout
    public var crankPlane: CrankPlane
    public var automatic: Bool
    /// False when gear ratios are the typical fallback; estimates widen.
    public var realGears: Bool

    public init(hpCrank: Double, torqueLbFt: Double, weightLb: Double, drivetrain: Drivetrain = .rwd,
                aspiration: Aspiration = .natural, redline: Double = 6500, gearRatios: [Double]? = nil,
                finalDrive: Double? = nil, tireRadiusM: Double = 0.33, cdA: Double = 0.7, cylinders: Int = 4,
                layout: EngineLayout = .inline, crankPlane: CrankPlane = .flat, automatic: Bool = false) {
        self.hpCrank = hpCrank; self.torqueLbFt = torqueLbFt; self.weightLb = weightLb; self.drivetrain = drivetrain
        self.aspiration = aspiration; self.redline = redline
        let real = gearRatios?.isEmpty == false
        self.realGears = real
        let ratios = gearRatios.flatMap { $0.isEmpty ? nil : $0 }
            ?? (automatic ? [4.17, 2.34, 1.52, 1.14, 0.87, 0.69] : [3.66, 2.43, 1.69, 1.32, 1.0, 0.65])
        self.gearRatios = ratios
        // Without the real ratios, gear the car the way makers do: first gear runs out near
        // 38 mph (17 m/s) at redline, whatever the engine revs to.
        self.finalDrive = finalDrive
            ?? (real ? 3.55 : redline / 60 * 2 * .pi * tireRadiusM / (17 * ratios[0]))
        self.tireRadiusM = tireRadiusM; self.cdA = cdA; self.cylinders = cylinders
        self.layout = layout; self.crankPlane = crankPlane; self.automatic = automatic
    }

    /// Builds a spec from a catalog row, the car's overrides, and sensible fills. `nil` when
    /// neither power nor weight is known (G6 then asks for them).
    public static func from(variant: CatalogVariant?, car: Car) -> VehicleSpec? {
        let o = car.specOverrides
        guard let hp = o.hp ?? variant?.hp else { return nil }
        let weight = Double(o.weightLb ?? variant?.weightLb ?? 3400)
        let cyl = variant?.cylinders ?? 4
        let engine = (variant?.engine ?? "").lowercased()
        let layout: EngineLayout = engine.contains("rotary") ? .rotary
            : (engine.contains("flat") || engine.contains("boxer") || car.make == "Subaru" || car.make == "Porsche") && cyl != 8 ? .flat
            : cyl >= 6 && !engine.contains("inline") && !(car.make == "BMW" && cyl == 6) ? .v : .inline
        let trans = (variant?.transmission ?? "").lowercased()
        let auto = trans.contains("auto") || trans.contains("cvt") || trans.contains("dct")
        let tq = Double(o.torqueLbFt ?? variant?.torqueLbFt ?? Int(Double(hp) * 0.9))
        let flatPlane = ["Ferrari", "McLaren"].contains(car.make) || car.model.contains("GT350")
        return VehicleSpec(hpCrank: Double(hp), torqueLbFt: tq, weightLb: weight,
                           drivetrain: o.drivetrain ?? variant?.drive ?? .rwd, aspiration: variant?.aspiration ?? .natural,
                           redline: Double(o.redline ?? variant?.redline ?? (cyl >= 8 ? 6500 : 7000)),
                           gearRatios: o.gears ?? variant?.gears, cylinders: cyl, layout: layout,
                           crankPlane: cyl == 8 && !flatPlane ? .cross : .flat, automatic: auto)
    }

    var isTurbo: Bool { aspiration == .turbo || aspiration == .twinCharged }
}

public struct CurvePoint: Sendable, Hashable {
    public var rpm: Double
    public var hp: Double
    public var torque: Double
}

public struct Estimate: Sendable, Hashable {
    public var hp: ClosedRange<Double>
    public var torque: ClosedRange<Double>
    public var zeroToSixty: ClosedRange<Double>
    public var quarterET: ClosedRange<Double>
    public var quarterTrap: ClosedRange<Double>
    /// Midpoint curve.
    public var curve: [CurvePoint]
}

// MARK: Power with mods

/// Gains as fractions (0.05 = 5%) at the low or high end.
struct Gains { var power: Double; var torque: Double; var absolute: (hp: Double, tq: Double)? }

func gains(for spec: VehicleSpec, mods: [Mod], high: Bool) -> Gains {
    let applicable = mods.filter { $0.applies(to: spec) }
    if let kit = applicable.first(where: { $0.category == .forcedInduction && $0.absolute != nil }), let abs = kit.absolute {
        return Gains(power: 0, torque: 0, absolute: abs)
    }
    let tuned = applicable.contains { $0.category == .tune }
    let bMax = spec.isTurbo ? 0.12 : 0.08
    var keepP = 1.0, keepT = 1.0
    var tuneP = 1.0, tuneT = 1.0
    var kitP = 1.0, kitT = 1.0
    for m in applicable {
        var p = (high ? m.hpGainPct.upperBound : m.hpGainPct.lowerBound) / 100
        var t = (high ? m.tqGainPct.upperBound : m.tqGainPct.lowerBound) / 100
        if m.requiresTune && !tuned { p /= 4; t /= 4 }
        switch m.category {
        case .intake, .exhaust:
            keepP *= 1 - min(p, bMax) / bMax
            keepT *= 1 - min(t, bMax) / bMax
        case .tune, .fuel:
            tuneP *= 1 + p
            tuneT *= 1 + t
        case .forcedInduction:
            kitP *= 1 + p
            kitT *= 1 + t
        case .weight:
            break
        }
    }
    let bP = bMax * (1 - keepP), bT = bMax * (1 - keepT)
    return Gains(power: (1 + bP) * tuneP * kitP - 1, torque: (1 + bT) * tuneT * kitT - 1, absolute: nil)
}

/// Spec after mods at one end of the range.
public func modified(_ spec: VehicleSpec, mods: [Mod], high: Bool) -> VehicleSpec {
    var s = spec
    let g = gains(for: spec, mods: mods, high: high)
    if let abs = g.absolute {
        s.hpCrank = abs.hp
        s.torqueLbFt = abs.tq
        if s.aspiration == .natural { s.aspiration = .supercharged }
    } else {
        s.hpCrank *= 1 + g.power
        s.torqueLbFt *= 1 + g.torque
    }
    s.weightLb += mods.filter { $0.applies(to: spec) }.reduce(0) { $0 + $1.weightDeltaLb }
    if mods.contains(where: { $0.category == .forcedInduction && $0.applies(to: spec) }) && spec.aspiration == .natural {
        s.aspiration = .supercharged
    }
    return s
}

// MARK: Torque curve

/// Torque at rpm, synthesized from peak power, peak torque, and redline; shape by aspiration.
/// Low in the range the torque shape limits; high in the range the rated power does, held flat
/// to 92% of redline and falling 12% by redline, so the curve reaches the rated peak power
/// (MOD-13: without that, every reference car ran slow).
public func torque(at rpm: Double, spec: VehicleSpec) -> Double {
    let x = max(0.1, min(rpm / spec.redline, 1.05))
    let shape: Double
    switch spec.aspiration {
    case .turbo, .twinCharged:
        shape = x < 0.3 ? 0.55 + 1.5 * x : 1
    case .supercharged:
        shape = x < 0.2 ? 0.8 + x : 1
    default:
        shape = 0.72 + 0.28 * sin(min(x / 0.6, 1) * .pi / 2)
    }
    let powerCap = spec.hpCrank * 5252 / max(rpm, 1) * (1 - 1.5 * max(0, x - 0.92))
    return min(spec.torqueLbFt * shape, powerCap)
}

public func curve(for spec: VehicleSpec, step: Double = 250) -> [CurvePoint] {
    stride(from: 1000.0, through: spec.redline, by: step).map { rpm in
        let tq = torque(at: rpm, spec: spec)
        return CurvePoint(rpm: rpm, hp: tq * rpm / 5252, torque: tq)
    }
}

// MARK: Longitudinal simulation

public struct RunInputs: Sendable, Hashable {
    public var launchRpm: Double
    /// Shift at this fraction of redline when no live input drives the run.
    public var shiftAt: Double
    public var reactionMs: Int
    public init(launchRpm: Double = 3500, shiftAt: Double = 0.97, reactionMs: Int = 0) {
        self.launchRpm = launchRpm; self.shiftAt = shiftAt; self.reactionMs = reactionMs
    }
}

public struct RunResult: Sendable, Hashable {
    public var reactionMs: Int
    public var sixtyFt: Double
    public var eighthET: Double
    public var eighthMph: Double
    public var quarterET: Double
    public var quarterMph: Double
    public var zeroToSixty: Double
}

/// One step-driven run. The Strip calls `step` at 240 Hz with the player's inputs; `simulateRun`
/// drives it with fixed inputs.
public struct RunState: Sendable {
    public let spec: VehicleSpec
    public private(set) var time = 0.0
    public private(set) var distance = 0.0
    public private(set) var speed = 0.0
    public private(set) var rpm: Double
    public private(set) var gear = 0
    public private(set) var shiftTimer = 0.0
    public private(set) var finished = false
    public private(set) var sixtyFt: Double?
    public private(set) var eighth: (et: Double, mph: Double)?
    public private(set) var quarter: (et: Double, mph: Double)?
    public private(set) var zeroToSixty: Double?
    private var rolloutAt: Double?
    /// Engine speed the slipping clutch holds until the wheels catch up.
    private let clutchRpm: Double

    static let rho = 1.2, g = 9.81, crr = 0.012, mu = 1.1, h = 0.2
    static let quarterM = 402.336, eighthM = 201.168, sixtyFtM = 18.288, rolloutM = 0.3048

    public init(spec: VehicleSpec, launchRpm: Double) {
        self.spec = spec
        rpm = launchRpm
        clutchRpm = min(launchRpm, spec.redline * 0.9)
    }

    private var mass: Double { spec.weightLb * 0.4536 + 80 }
    private var eta: Double { spec.drivetrain == .awd || spec.drivetrain == .fourWD ? 0.85 : spec.automatic ? 0.87 : 0.88 }
    private var shiftTime: Double { spec.automatic ? 0.12 : 0.2 }

    private func wheelRpm(_ v: Double, gear: Int) -> Double {
        v / spec.tireRadiusM * 60 / (2 * .pi) * spec.gearRatios[gear] * spec.finalDrive
    }

    public var mph: Double { speed * 2.23694 }

    /// Advances by dt. `throttle` 0–1; `shift` requests the next gear.
    public mutating func step(throttle: Double, shift: Bool, dt: Double) {
        guard !finished else { return }
        if shift && gear < spec.gearRatios.count - 1 && shiftTimer <= 0 {
            gear += 1
            shiftTimer = shiftTime
        }
        let m = mass
        let ratio = spec.gearRatios[gear] * spec.finalDrive
        let coupled = wheelRpm(speed, gear: gear)
        let engineRpm: Double
        if gear == 0 && coupled < clutchRpm && speed < 8 {
            engineRpm = max(coupled, clutchRpm)           // clutch slip holds launch rpm
        } else {
            engineRpm = max(coupled, 900)
        }
        rpm = min(engineRpm, spec.redline * 1.02)
        var drive = 0.0
        if shiftTimer > 0 {
            shiftTimer -= dt
        } else if rpm < spec.redline * 1.01 {
            let tqNm = torque(at: rpm, spec: spec) * 1.3558 * throttle
            drive = tqNm * ratio * eta / spec.tireRadiusM
        }
        let wf = spec.drivetrain == .fwd ? 0.6 : 0.52
        let traction: Double = switch spec.drivetrain {
        case .rwd: Self.mu * (1 - wf) / (1 - Self.mu * Self.h) * m * Self.g
        case .fwd: Self.mu * wf / (1 + Self.mu * Self.h) * m * Self.g
        default: Self.mu * m * Self.g
        }
        let resist = 0.5 * Self.rho * spec.cdA * speed * speed + Self.crr * m * Self.g
        let k = 1.15 - 0.1 * Double(gear) / Double(max(1, spec.gearRatios.count - 1))
        // The inertia factor scales what the engine can accelerate; a tire at its grip limit
        // pushes the car's mass directly.
        let a = (min(drive / k, traction) - resist) / m
        speed = max(0, speed + a * dt)
        distance += speed * dt
        time += dt
        if rolloutAt == nil && distance >= Self.rolloutM { rolloutAt = time }
        let t0 = rolloutAt ?? 0
        if zeroToSixty == nil && speed >= 26.8224 { zeroToSixty = time - t0 }
        if sixtyFt == nil && distance >= Self.sixtyFtM { sixtyFt = time - t0 }
        if eighth == nil && distance >= Self.eighthM { eighth = (time - t0, mph) }
        if quarter == nil && distance >= Self.quarterM {
            quarter = (time - t0, mph)
            finished = true
        }
        if time > 60 { finished = true }
    }

    public func result(reactionMs: Int) -> RunResult {
        RunResult(reactionMs: reactionMs, sixtyFt: sixtyFt ?? 0, eighthET: eighth?.et ?? 0, eighthMph: eighth?.mph ?? 0,
                  quarterET: quarter?.et ?? time, quarterMph: quarter?.mph ?? mph, zeroToSixty: zeroToSixty ?? time)
    }
}

public func simulateRun(spec: VehicleSpec, mods: [Mod], inputs: RunInputs, dt: Double = 0.004) -> RunResult {
    var s = RunState(spec: modified(spec, mods: mods, high: false), launchRpm: inputs.launchRpm)
    while !s.finished {
        s.step(throttle: 1, shift: s.rpm >= s.spec.redline * inputs.shiftAt, dt: dt)
    }
    return s.result(reactionMs: inputs.reactionMs)
}

func run(_ spec: VehicleSpec) -> RunResult {
    // Launch near peak torque for a typical street launch.
    simulateRun(spec: spec, mods: [], inputs: RunInputs(launchRpm: min(spec.redline * 0.55, 4500)))
}

/// Estimate for a car with mods. Ranges cover the low and high end of every mod, the stated
/// model error, and Hale's formulas when they disagree by more than 12%.
public func estimate(base: VehicleSpec, mods: [Mod]) -> Estimate {
    let lo = modified(base, mods: mods, high: false), hi = modified(base, mods: mods, high: true)
    let rLo = run(lo), rHi = run(hi)
    let err = base.realGears ? 1.0 : 2.0
    func range(_ a: Double, _ b: Double, pct: Double) -> ClosedRange<Double> {
        let lo = min(a, b) * (1 - pct * err), hi = max(a, b) * (1 + pct * err)
        return lo...hi
    }
    var et = range(rHi.quarterET, rLo.quarterET, pct: 0.05)
    var trap = range(rLo.quarterMph, rHi.quarterMph, pct: 0.03)
    let haleET = 5.825 * pow(lo.weightLb / lo.hpCrank, 1.0 / 3)
    let haleMph = 234 * pow(lo.hpCrank / lo.weightLb, 1.0 / 3)
    if abs(haleET - rLo.quarterET) / haleET > 0.12 { et = min(et.lowerBound, haleET)...max(et.upperBound, haleET) }
    if abs(haleMph - rLo.quarterMph) / haleMph > 0.12 { trap = min(trap.lowerBound, haleMph)...max(trap.upperBound, haleMph) }
    let mid = modified(base, mods: mods, high: true)
    var midSpec = mid
    midSpec.hpCrank = (lo.hpCrank + hi.hpCrank) / 2
    midSpec.torqueLbFt = (lo.torqueLbFt + hi.torqueLbFt) / 2
    return Estimate(hp: lo.hpCrank...hi.hpCrank, torque: lo.torqueLbFt...hi.torqueLbFt,
                    zeroToSixty: max(0, min(rHi.zeroToSixty, rLo.zeroToSixty) - 0.4 * err)...(max(rHi.zeroToSixty, rLo.zeroToSixty) + 0.4 * err),
                    quarterET: et, quarterTrap: trap, curve: curve(for: midSpec))
}
