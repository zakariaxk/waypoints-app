import SwiftUI

// Vehicle silhouettes (plan 9.8): top-down, nose up, on a 24 × 24 grid, filled, no interior
// detail. Types differ by proportion only: length, width, cab, overhangs, wing.

/// Proportions of one silhouette, in grid units of a 24 × 24 box.
struct SilhouetteSpec: Sendable {
    var length: CGFloat = 20       // nose to tail
    var width: CGFloat = 10
    var noseTaper: CGFloat = 0.25  // 0 square, 1 pointed
    var tailTaper: CGFloat = 0.1
    var cabin: ClosedRange<CGFloat>? = nil   // a narrower cab section (pickups, vans)
    var wing: CGFloat = 0          // rear wing span beyond the body
    var bar: Bool = false          // light bar across the roof
    var bike: Bool = false
    var hood: CGFloat = 0.34
    var openWheels: Bool = false

    static let table: [String: SilhouetteSpec] = [
        "coupe": .init(length: 19, width: 10, noseTaper: 0.35, tailTaper: 0.2, hood: 0.38),
        "sedan": .init(length: 21, width: 10, noseTaper: 0.3, tailTaper: 0.15, hood: 0.33),
        "hatch": .init(length: 17, width: 10, noseTaper: 0.3, tailTaper: 0.05, hood: 0.29),
        "wagon": .init(length: 21, width: 10, noseTaper: 0.3, tailTaper: 0.02, hood: 0.29),
        "roadster": .init(length: 17, width: 9.5, noseTaper: 0.45, tailTaper: 0.25, hood: 0.46),
        "muscle": .init(length: 21, width: 11, noseTaper: 0.15, tailTaper: 0.1, hood: 0.44),
        "pony": .init(length: 20, width: 10.5, noseTaper: 0.25, tailTaper: 0.12, hood: 0.41),
        "supercar": .init(length: 20, width: 11.5, noseTaper: 0.55, tailTaper: 0.2, wing: 0.8, hood: 0.37),
        "kei": .init(length: 14, width: 9, noseTaper: 0.1, tailTaper: 0.02, hood: 0.22),
        "pickup": .init(length: 22, width: 11, noseTaper: 0.12, tailTaper: 0, cabin: 0.25...0.55),
        "suv": .init(length: 20, width: 11, noseTaper: 0.12, tailTaper: 0.02, hood: 0.27),
        "van": .init(length: 21, width: 10.5, noseTaper: 0.05, tailTaper: 0, hood: 0.12),
        "classic": .init(length: 21, width: 10.5, noseTaper: 0.2, tailTaper: 0.25, hood: 0.42),
        "hot_rod": .init(length: 18, width: 9, noseTaper: 0.6, tailTaper: 0.3, openWheels: true),
        "sport_bike": .init(length: 18, width: 4, noseTaper: 0.5, tailTaper: 0.4, bike: true),
        "cruiser_bike": .init(length: 19, width: 5, noseTaper: 0.3, tailTaper: 0.3, bike: true),
        "time_attack": .init(length: 20, width: 11, noseTaper: 0.4, tailTaper: 0.1, wing: 2),
        "drift": .init(length: 19, width: 12, noseTaper: 0.3, tailTaper: 0.05, wing: 1.2),
        "rally": .init(length: 17, width: 10.5, noseTaper: 0.25, tailTaper: 0.05, wing: 0.5, hood: 0.3),
        "lowrider": .init(length: 22, width: 10.5, noseTaper: 0.15, tailTaper: 0.2, hood: 0.4),
        "lifted_truck": .init(length: 22, width: 12.5, noseTaper: 0.08, tailTaper: 0, cabin: 0.2...0.5),
        "dually": .init(length: 23, width: 12, noseTaper: 0.1, tailTaper: -0.15, cabin: 0.2...0.5),
        "wide_body": .init(length: 19, width: 12.5, noseTaper: 0.35, tailTaper: 0.15, wing: 0.6),
        "fastback_classic": .init(length: 21, width: 10.5, noseTaper: 0.2, tailTaper: 0.45, hood: 0.42),
        "woody_wagon": .init(length: 22, width: 10.5, noseTaper: 0.2, tailTaper: 0),
        "microcar": .init(length: 11, width: 8, noseTaper: 0.3, tailTaper: 0.3, hood: 0.3),
        "van_camper": .init(length: 21, width: 11, noseTaper: 0.08, tailTaper: 0, cabin: 0.0...0.2),
        "ute": .init(length: 21, width: 10.5, noseTaper: 0.25, tailTaper: 0, cabin: 0.35...0.55),
        "shooting_brake": .init(length: 20, width: 10, noseTaper: 0.45, tailTaper: 0.04, hood: 0.43),
        "targa": .init(length: 18, width: 10, noseTaper: 0.45, tailTaper: 0.2, cabin: 0.45...0.55),
        "gt_wing_hatch": .init(length: 17, width: 10.5, noseTaper: 0.3, tailTaper: 0.05, wing: 1.5, hood: 0.29),
        "rat_rod": .init(length: 19, width: 8.5, noseTaper: 0.7, tailTaper: 0.2, cabin: 0.5...0.7, openWheels: true),
        "restomod": .init(length: 20, width: 11, noseTaper: 0.25, tailTaper: 0.2, hood: 0.42),
        "box_truck": .init(length: 23, width: 11.5, noseTaper: 0.08, tailTaper: 0, cabin: 0.0...0.22),
        "flatbed": .init(length: 23, width: 11, noseTaper: 0.08, tailTaper: 0, cabin: 0.0...0.25),
        "safety_car": .init(length: 20, width: 10.5, noseTaper: 0.3, tailTaper: 0.15, bar: true),
    ]

    static func named(_ name: String) -> SilhouetteSpec { table[name] ?? table["coupe"]! }
}

/// The silhouette as a filled shape, nose up.
public struct VehicleSilhouette: Shape {
    let spec: SilhouetteSpec
    public init(_ name: String) { spec = SilhouetteSpec.named(name) }

    public func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 24
        let cx = rect.midX
        let top = rect.midY - spec.length * unit / 2
        let bottom = rect.midY + spec.length * unit / 2
        let half = spec.width * unit / 2
        var p = Path()
        if spec.bike {
            p.addEllipse(in: CGRect(x: cx - half, y: top, width: half * 2, height: bottom - top))
            p.addRect(CGRect(x: cx - half * 2.2, y: top + (bottom - top) * 0.3, width: half * 4.4, height: unit * 1.2))
            return p
        }
        let nose = half * (1 - min(max(spec.noseTaper, 0), 0.9))
        let tail = half * (1 - min(max(spec.tailTaper, -0.3), 0.9))
        let noseLength = unit * (2 + 7 * min(max(spec.noseTaper, 0), 0.9))
        let tailLength = unit * (1.5 + 6 * min(max(spec.tailTaper, 0), 0.9))
        let cab = spec.cabin.map { (max(top + (bottom - top) * $0.lowerBound, top + noseLength), top + (bottom - top) * $0.upperBound) }
        p.move(to: CGPoint(x: cx, y: top))
        p.addCurve(to: CGPoint(x: cx + half, y: top + noseLength),
                   control1: CGPoint(x: cx + nose, y: top), control2: CGPoint(x: cx + half, y: top + noseLength * 0.35))
        if let (y0, y1) = cab {
            p.addLine(to: CGPoint(x: cx + half, y: y0))
            p.addLine(to: CGPoint(x: cx + half * 0.86, y: y0 + unit * 0.6))
            p.addLine(to: CGPoint(x: cx + half * 0.86, y: y1))
            p.addLine(to: CGPoint(x: cx + half, y: y1 + unit * 0.6))
        }
        p.addLine(to: CGPoint(x: cx + half, y: bottom - tailLength))
        p.addCurve(to: CGPoint(x: cx, y: bottom),
                   control1: CGPoint(x: cx + half, y: bottom - tailLength * 0.35), control2: CGPoint(x: cx + tail, y: bottom))
        p.addCurve(to: CGPoint(x: cx - half, y: bottom - tailLength),
                   control1: CGPoint(x: cx - tail, y: bottom), control2: CGPoint(x: cx - half, y: bottom - tailLength * 0.35))
        if let (y0, y1) = cab {
            p.addLine(to: CGPoint(x: cx - half, y: y1 + unit * 0.6))
            p.addLine(to: CGPoint(x: cx - half * 0.86, y: y1))
            p.addLine(to: CGPoint(x: cx - half * 0.86, y: y0 + unit * 0.6))
            p.addLine(to: CGPoint(x: cx - half, y: y0))
        }
        p.addLine(to: CGPoint(x: cx - half, y: top + noseLength))
        p.addCurve(to: CGPoint(x: cx, y: top),
                   control1: CGPoint(x: cx - half, y: top + noseLength * 0.35), control2: CGPoint(x: cx - nose, y: top))
        p.closeSubpath()
        for side: CGFloat in [-1, 1] {
            if spec.openWheels {
                for y in [top + unit * 2, bottom - unit * 6] {
                    p.addRoundedRect(in: CGRect(x: cx + side * (half + unit * 1.3) - unit, y: y, width: unit * 2, height: unit * 3.6),
                                     cornerSize: CGSize(width: unit * 0.6, height: unit * 0.6))
                }
            } else {
                let inset = spec.cabin == nil ? half : half * 0.86
                let y = max(cab?.0 ?? top + (bottom - top) * spec.hood, top + noseLength) + unit * 0.6
                p.move(to: CGPoint(x: cx + side * (inset - unit * 0.2), y: y))
                p.addLine(to: CGPoint(x: cx + side * (half + unit * 1.2), y: y + unit * 0.5))
                p.addLine(to: CGPoint(x: cx + side * (half + unit * 1.2), y: y + unit * 1.3))
                p.addLine(to: CGPoint(x: cx + side * (inset - unit * 0.2), y: y + unit * 1.6))
                p.closeSubpath()
            }
        }
        if spec.wing > 0 {
            p.addRoundedRect(in: CGRect(x: cx - half - spec.wing * unit, y: bottom - unit * 2.2,
                                        width: (half + spec.wing * unit) * 2, height: unit * 1.1),
                             cornerSize: CGSize(width: unit * 0.4, height: unit * 0.4))
        }
        if spec.bar {
            p.addRect(CGRect(x: cx - half * 0.8, y: rect.midY - unit * 0.6, width: half * 1.6, height: unit * 1.2))
        }
        return p
    }
}

/// Names and unlock state for the marker picker (M10).
public enum MapIconSet {
    public static let earnedVehicles = [
        "time_attack", "drift", "rally", "lowrider", "lifted_truck", "dually", "wide_body", "fastback_classic",
        "woody_wagon", "microcar", "van_camper", "ute", "shooting_brake", "targa", "gt_wing_hatch", "rat_rod",
        "restomod", "box_truck", "flatbed", "safety_car",
    ]
    public static let trails = ["none", "dash", "double", "chevrons", "dots", "checker", "tread", "comet"]

    /// Display name: "hot_rod" → "Hot rod".
    public static func title(_ name: String) -> String {
        let s = name.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}
