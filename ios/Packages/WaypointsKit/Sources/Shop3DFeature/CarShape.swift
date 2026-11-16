import Foundation

/// Proportions for a generated car body, in meters (GME-1). The catalog carries no
/// dimensions, so a shape is picked by body class — the `MapGlyph` vehicle name is the
/// closest thing a `Car` has to one.
public struct CarShape: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case sedan, coupe, hatch, suv, truck
    }

    public var kind: Kind
    public var length: Float
    public var width: Float
    /// Height of the lower hull (fender line) at stock clearance.
    public var hullHeight: Float
    /// Greenhouse height above the hull.
    public var cabinHeight: Float
    public var wheelbase: Float
    public var wheelRadius: Float
    public var wheelWidth: Float
    /// Cabin footprint as a fraction of length measured back from the nose.
    public var cabinFront: Float
    public var cabinRear: Float

    /// Wheel center offset from the centerline.
    public var track: Float { width - wheelWidth }

    public init(kind: Kind, length: Float, width: Float, hullHeight: Float, cabinHeight: Float,
                wheelbase: Float, wheelRadius: Float, wheelWidth: Float, cabinFront: Float, cabinRear: Float) {
        self.kind = kind; self.length = length; self.width = width
        self.hullHeight = hullHeight; self.cabinHeight = cabinHeight
        self.wheelbase = wheelbase; self.wheelRadius = wheelRadius; self.wheelWidth = wheelWidth
        self.cabinFront = cabinFront; self.cabinRear = cabinRear
    }

    public static func `for`(_ kind: Kind) -> CarShape {
        switch kind {
        case .sedan:
            return CarShape(kind: .sedan, length: 4.85, width: 1.86, hullHeight: 0.60, cabinHeight: 0.50,
                            wheelbase: 2.85, wheelRadius: 0.335, wheelWidth: 0.24,
                            cabinFront: 0.30, cabinRear: 0.72)
        case .coupe:
            return CarShape(kind: .coupe, length: 4.65, width: 1.88, hullHeight: 0.58, cabinHeight: 0.44,
                            wheelbase: 2.75, wheelRadius: 0.34, wheelWidth: 0.26,
                            cabinFront: 0.38, cabinRear: 0.78)
        case .hatch:
            return CarShape(kind: .hatch, length: 4.25, width: 1.80, hullHeight: 0.62, cabinHeight: 0.55,
                            wheelbase: 2.60, wheelRadius: 0.32, wheelWidth: 0.22,
                            cabinFront: 0.26, cabinRear: 0.78)
        case .suv:
            return CarShape(kind: .suv, length: 4.75, width: 1.92, hullHeight: 0.78, cabinHeight: 0.70,
                            wheelbase: 2.80, wheelRadius: 0.38, wheelWidth: 0.26,
                            cabinFront: 0.24, cabinRear: 0.80)
        case .truck:
            return CarShape(kind: .truck, length: 5.30, width: 2.03, hullHeight: 0.85, cabinHeight: 0.68,
                            wheelbase: 3.35, wheelRadius: 0.41, wheelWidth: 0.30,
                            cabinFront: 0.10, cabinRear: 0.40)
        }
    }

    /// `MapGlyph` vehicle names (plan 9.8) mapped onto the five generated classes.
    public init(className: String) {
        let kind: Kind = switch className {
        case "sedan", "wagon", "woody_wagon", "lowrider", "safety_car", "restomod": .sedan
        case "hatch", "kei", "microcar", "shooting_brake", "gt_wing_hatch", "rally": .hatch
        case "suv", "van", "van_camper", "wide_body": .suv
        case "pickup", "ute", "lifted_truck", "dually", "flatbed", "box_truck": .truck
        default: .coupe   // coupe, pony, roadster, muscle, supercar, classic, hot_rod, bikes, …
        }
        self = .for(kind)
    }
}
