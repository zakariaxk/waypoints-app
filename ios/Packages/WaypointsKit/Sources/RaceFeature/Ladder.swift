import Core
import Foundation
import PerformanceModel

/// STR-9: ten house cars from about 16.5 s to about 9 s, defined by plain specs. Beating the
/// highest open car opens the next; progress is kept on this phone (`openedKey`), since it is a
/// single-player game and no time ever leaves the device for it.
struct HouseCar: Hashable, Identifiable {
    var id: Int { rung }
    let rung: Int
    let spec: VehicleSpec

    var title: String { "House car \(rung + 1)" }

    /// "175 hp, 2,900 lb, front-drive automatic".
    var specLine: String {
        let drive = switch spec.drivetrain {
        case .fwd: "front-drive"
        case .rwd: "rear-drive"
        case .awd: "all-wheel-drive"
        case .fourWD: "four-wheel-drive"
        }
        let boost = spec.aspiration == .turbo ? " turbo" : spec.aspiration == .supercharged ? " supercharged" : ""
        let lb = Int(spec.weightLb).formatted(.number.grouping(.automatic))
        return "\(Int(spec.hpCrank)) hp\(boost), \(lb) lb, \(drive) \(spec.automatic ? "automatic" : "manual")"
    }
}

enum Ladder {
    static let openedKey = "strip.ladder.opened"
    static let treeKey = "strip.tree"

    /// Model times with a perfect launch, for reference: 16.4, 15.5, 14.9, 14.2, 13.2, 12.5,
    /// 11.4, 10.7, 9.9, 9.0 s.
    static let cars: [HouseCar] = [
        VehicleSpec(hpCrank: 175, torqueLbFt: 150, weightLb: 2900, drivetrain: .fwd, redline: 6500, automatic: true),
        VehicleSpec(hpCrank: 172, torqueLbFt: 165, weightLb: 2950, drivetrain: .fwd, redline: 6800),
        VehicleSpec(hpCrank: 205, torqueLbFt: 175, weightLb: 3050, redline: 7200, cylinders: 4, layout: .flat),
        VehicleSpec(hpCrank: 265, torqueLbFt: 260, weightLb: 3200, drivetrain: .fwd, aspiration: .turbo, redline: 6800),
        VehicleSpec(hpCrank: 320, torqueLbFt: 300, weightLb: 3400, drivetrain: .awd, aspiration: .turbo, redline: 6800),
        VehicleSpec(hpCrank: 470, torqueLbFt: 420, weightLb: 3800, redline: 7000, cylinders: 8, layout: .v, crankPlane: .cross),
        VehicleSpec(hpCrank: 485, torqueLbFt: 480, weightLb: 3600, drivetrain: .awd, aspiration: .turbo, redline: 7000,
                    cylinders: 6, layout: .v, automatic: true),
        VehicleSpec(hpCrank: 580, torqueLbFt: 560, weightLb: 3400, drivetrain: .awd, aspiration: .turbo, redline: 7500,
                    cylinders: 8, layout: .v, crankPlane: .flat, automatic: true),
        VehicleSpec(hpCrank: 820, torqueLbFt: 700, weightLb: 3300, drivetrain: .awd, aspiration: .turbo, redline: 7500,
                    cylinders: 8, layout: .v, crankPlane: .flat, automatic: true),
        VehicleSpec(hpCrank: 1400, torqueLbFt: 1050, weightLb: 2750, drivetrain: .awd, aspiration: .turbo, redline: 8000,
                    cylinders: 8, layout: .v, crankPlane: .flat, automatic: true),
    ].enumerated().map { HouseCar(rung: $0.offset, spec: $0.element) }
}

/// STR-9 tree choice. Timing is NHRA's (https://www.nhra.com/nhra-101): a Sportsman (full) tree
/// lights the ambers 0.5 s apart with green 0.5 s after the last; a Pro tree lights all three at
/// once with green 0.4 s later.
enum TreeKind: String, CaseIterable {
    case sportsman, pro

    /// (delay in ms, how many ambers are lit after it; 4 means green).
    var sequence: [(ms: Int, lit: Int)] {
        switch self {
        case .sportsman: [(1500, 1), (500, 2), (500, 3), (500, 4)]
        case .pro: [(1500, 3), (400, 4)]
        }
    }

    var detail: String {
        switch self {
        case .sportsman: "Ambers one at a time, half a second apart, then green."
        case .pro: "All three ambers at once, green 0.4 s later."
        }
    }
}
