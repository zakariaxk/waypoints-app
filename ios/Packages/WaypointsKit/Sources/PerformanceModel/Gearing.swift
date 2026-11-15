import Foundation

// GAR-17: gearing and tire arithmetic. Pure geometry from the inputs given; nothing is filled
// in when an input is missing (the caller says so instead).

/// A metric tire size, "245/30R20": section width in mm, aspect ratio in percent, rim in inches.
public struct TireSize: Sendable, Hashable {
    public var widthMM: Double
    public var aspect: Double
    public var rimIn: Double

    /// `nil` outside the sizes road tires come in.
    public init?(widthMM: Double, aspect: Double, rimIn: Double) {
        guard (105...455).contains(widthMM), (20...95).contains(aspect), (10...30).contains(rimIn) else { return nil }
        self.widthMM = widthMM; self.aspect = aspect; self.rimIn = rimIn
    }

    /// Nominal overall diameter in metres: the rim plus two sidewalls.
    public var diameterM: Double { (rimIn * 25.4 + 2 * widthMM * aspect / 100) / 1000 }
}

public enum Gearing {
    /// Road speed in m/s at `rpm` in a gear of ratio `gear`.
    public static func speed(rpm: Double, gear: Double, finalDrive: Double, tire: TireSize) -> Double {
        rpm / 60 / (gear * finalDrive) * .pi * tire.diameterM
    }

    /// Engine rpm at a road speed in m/s in a gear of ratio `gear`.
    public static func rpm(speed: Double, gear: Double, finalDrive: Double, tire: TireSize) -> Double {
        speed / (.pi * tire.diameterM) * gear * finalDrive * 60
    }

    /// True speed divided by the speed shown, after a tire or final drive change, for a
    /// speedometer driven from the transmission and calibrated for the stock setup.
    /// 1.03 means the car travels 3% faster than the speedometer reads.
    public static func speedometerRatio(stockTire: TireSize, newTire: TireSize,
                                        stockFinalDrive: Double, newFinalDrive: Double) -> Double {
        newTire.diameterM / stockTire.diameterM * stockFinalDrive / newFinalDrive
    }
}
