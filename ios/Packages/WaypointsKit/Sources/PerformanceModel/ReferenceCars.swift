import Core
import Foundation

// MOD-13 (plan 11.2 "Honesty"): twelve stock cars with instrumented times, so the model's error
// can be read off a debug screen instead of trusted. Every row was copied from the test page in
// `sourceURL`, opened when the row was written. Car and Driver figures omit a one-foot rollout,
// which matches the simulation's timing.
//
// Specs are what the catalog would hold for the car (power, torque, curb weight as tested,
// drivetrain, aspiration, layout, transmission type), so the check exercises the same fills as a
// garage car: typical gear ratios, final drive, tire radius, and CdA. `redline` is the published
// redline where the page gives one, otherwise the rpm of peak power from the same page.

public struct ReferenceCar: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let spec: VehicleSpec
    public let zeroToSixty: Double
    public let quarterET: Double
    public let quarterMph: Double
    public let sourceURL: String
}

/// One reference car against the model.
public struct ReferenceCheck: Sendable, Hashable, Identifiable {
    public var id: String { car.id }
    public let car: ReferenceCar
    public let model: RunResult

    /// Stated error with real gear ratios (plan 11.2): trap ±3%, ET ±5%, 0–60 ±0.4 s.
    public static let trapTolerance = 0.03, etTolerance = 0.05, sixtyTolerance = 0.4

    public var trapError: Double { (model.quarterMph - car.quarterMph) / car.quarterMph }
    public var etError: Double { (model.quarterET - car.quarterET) / car.quarterET }
    public var sixtyError: Double { model.zeroToSixty - car.zeroToSixty }

    /// Inside the error stated for real gear ratios.
    public var withinStated: Bool {
        abs(trapError) <= Self.trapTolerance && abs(etError) <= Self.etTolerance && abs(sixtyError) <= Self.sixtyTolerance
    }

    /// Plan 11.2: without real ratios the error is about double. Rows here use typical ratios
    /// unless the spec carries real ones.
    public var errorScale: Double { car.spec.realGears ? 1 : 2 }
    public var trapPasses: Bool { abs(trapError) <= Self.trapTolerance * errorScale }
    public var etPasses: Bool { abs(etError) <= Self.etTolerance * errorScale }
    public var sixtyPasses: Bool { abs(sixtyError) <= Self.sixtyTolerance * errorScale }
    public var passes: Bool { trapPasses && etPasses && sixtyPasses }
}

public enum ReferenceCars {
    private static func v8(_ hp: Double, _ tq: Double, _ lb: Double, redline: Double, auto: Int? = nil,
                           drive: Drivetrain = .rwd) -> VehicleSpec {
        VehicleSpec(hpCrank: hp, torqueLbFt: tq, weightLb: lb, drivetrain: drive, redline: redline, cylinders: 8,
                    layout: .v, crankPlane: .cross, automatic: auto != nil, gearCount: auto)
    }

    public static let all: [ReferenceCar] = [
        ReferenceCar(name: "2024 Ford Mustang GT (6-speed manual)",
                     spec: v8(486, 418, 3947, redline: 7250),
                     zeroToSixty: 4.2, quarterET: 12.5, quarterMph: 114,
                     sourceURL: "https://www.caranddriver.com/reviews/a44892132/2024-ford-mustang-gt-test/"),
        ReferenceCar(name: "2018 Ford Mustang GT (10-speed automatic)",
                     spec: v8(460, 420, 3851, redline: 7400, auto: 10),
                     zeroToSixty: 3.8, quarterET: 12.1, quarterMph: 120,
                     sourceURL: "https://www.caranddriver.com/reviews/a24847025/2018-ford-mustang-automatic-transmission-performance/"),
        ReferenceCar(name: "2011 Ford Mustang GT 5.0 convertible (6-speed manual)",
                     spec: v8(412, 390, 3754, redline: 6500),
                     zeroToSixty: 4.7, quarterET: 13.2, quarterMph: 108,
                     sourceURL: "https://www.caranddriver.com/reviews/a15129850/2011-ford-mustang-gt-50-convertible-instrumented-test/"),
        ReferenceCar(name: "2017 Chevrolet Camaro SS 1LE (6-speed manual)",
                     spec: v8(455, 455, 3747, redline: 6500),
                     zeroToSixty: 4.1, quarterET: 12.4, quarterMph: 116,
                     sourceURL: "https://www.caranddriver.com/features/a15098588/chevrolet-camaro-2017-10best-cars-feature/"),
        ReferenceCar(name: "2015 Dodge Challenger R/T Scat Pack (8-speed automatic)",
                     spec: v8(485, 475, 4261, redline: 6000, auto: 8),
                     zeroToSixty: 4.2, quarterET: 12.6, quarterMph: 114,
                     sourceURL: "https://www.caranddriver.com/reviews/a15107205/2015-dodge-challenger-r-t-scat-pack-automatic-test-review/"),
        ReferenceCar(name: "2021 Ford F-150 5.0 4x4 (10-speed automatic)",
                     spec: v8(400, 410, 5687, redline: 6000, auto: 10, drive: .fourWD),
                     zeroToSixty: 6.2, quarterET: 14.6, quarterMph: 96.3,
                     sourceURL: "https://www.motortrend.com/reviews/2021-ford-f-150-v-8-first-test/"),
        ReferenceCar(name: "2023 Toyota GR Supra 3.0 (6-speed manual)",
                     spec: VehicleSpec(hpCrank: 382, torqueLbFt: 368, weightLb: 3343, aspiration: .turbo, redline: 6500,
                                       cylinders: 6, layout: .inline),
                     zeroToSixty: 3.9, quarterET: 12.4, quarterMph: 115,
                     sourceURL: "https://www.caranddriver.com/reviews/a41096194/2023-toyota-gr-supra-manual-drive/"),
        ReferenceCar(name: "2023 Honda Civic Type R (6-speed manual)",
                     spec: VehicleSpec(hpCrank: 315, torqueLbFt: 310, weightLb: 3183, drivetrain: .fwd, aspiration: .turbo,
                                       redline: 6500, cylinders: 4),
                     zeroToSixty: 4.9, quarterET: 13.5, quarterMph: 106,
                     sourceURL: "https://www.caranddriver.com/reviews/a41952459/2023-honda-civic-type-r-by-the-numbers/"),
        ReferenceCar(name: "2022 Subaru WRX Limited (6-speed manual)",
                     spec: VehicleSpec(hpCrank: 271, torqueLbFt: 258, weightLb: 3401, drivetrain: .awd, aspiration: .turbo,
                                       redline: 6100, cylinders: 4, layout: .flat),
                     zeroToSixty: 5.5, quarterET: 13.9, quarterMph: 101,
                     sourceURL: "https://www.caranddriver.com/reviews/a40026459/2022-subaru-wrx-limited-by-the-numbers/"),
        ReferenceCar(name: "2022 Toyota GR86 (6-speed manual)",
                     spec: VehicleSpec(hpCrank: 228, torqueLbFt: 184, weightLb: 2838, redline: 7500, cylinders: 4, layout: .flat),
                     zeroToSixty: 5.4, quarterET: 14.0, quarterMph: 101,
                     sourceURL: "https://www.caranddriver.com/reviews/a37322814/2022-toyota-gr86-drive/"),
        ReferenceCar(name: "2022 Honda Civic Si (6-speed manual)",
                     spec: VehicleSpec(hpCrank: 200, torqueLbFt: 192, weightLb: 2937, drivetrain: .fwd, aspiration: .turbo,
                                       redline: 6000, cylinders: 4),
                     zeroToSixty: 6.8, quarterET: 15.1, quarterMph: 94,
                     sourceURL: "https://www.caranddriver.com/reviews/a38381477/2022-honda-civic-si-drive/"),
        ReferenceCar(name: "2019 Mazda MX-5 Miata Club (6-speed manual)",
                     spec: VehicleSpec(hpCrank: 181, torqueLbFt: 151, weightLb: 2345, redline: 7500, cylinders: 4),
                     zeroToSixty: 5.7, quarterET: 14.5, quarterMph: 95,
                     sourceURL: "https://www.caranddriver.com/reviews/a22678665/2019-mazda-mx-5-miata-engine-more-power/"),
    ]

    /// The model's run for every reference car, launched the way `estimate` launches.
    public static func checks() -> [ReferenceCheck] {
        all.map { ReferenceCheck(car: $0, model: run($0.spec)) }
    }
}
