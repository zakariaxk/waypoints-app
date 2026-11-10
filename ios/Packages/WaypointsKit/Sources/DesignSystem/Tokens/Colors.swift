import SwiftUI
import UIKit

/// One color token (plan 9.2). `highContrast` is used when Increase Contrast is on (plan 9.12).
public struct ColorToken: Sendable, Hashable, Identifiable {
    public let name: String
    public let rgb: UInt32
    public let highContrast: UInt32?
    public var id: String { name }

    init(_ name: String, _ rgb: UInt32, highContrast: UInt32? = nil) {
        self.name = name
        self.rgb = rgb
        self.highContrast = highContrast
    }

    public var hex: String { String(format: "#%06X", rgb) }

    public var color: Color {
        guard let highContrast else { return Color(rgb: rgb) }
        let normal = rgb
        return Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.accessibilityContrast == .high ? highContrast : normal)
        })
    }
}

/// The palette. Final values after the W0-D contrast audit; `gravel` was lifted from #86847F to
/// #94928D so disabled labels on `curb` and tertiary text on `concrete` clear 4.5:1.
public enum Palette {
    public static let asphalt = ColorToken("asphalt", 0x0D0D0E)
    public static let tarmac = ColorToken("tarmac", 0x161617)
    public static let concrete = ColorToken("concrete", 0x202022)
    public static let curb = ColorToken("curb", 0x2B2B2E)
    public static let seam = ColorToken("seam", 0x37373B, highContrast: 0x55555B)
    public static let chalk = ColorToken("chalk", 0xF3F1EC, highContrast: 0xFFFFFF)
    public static let dust = ColorToken("dust", 0xA8A6A0, highContrast: 0xCFCDC7)
    public static let gravel = ColorToken("gravel", 0x94928D, highContrast: 0xB4B2AC)
    public static let sodium = ColorToken("sodium", 0xFFB224)
    public static let sodiumDim = ColorToken("sodiumDim", 0x3A2A0A)
    public static let brake = ColorToken("brake", 0xFF4B3A, highContrast: 0xFF6A5C)
    public static let go = ColorToken("go", 0x34D17C)
    public static let xenon = ColorToken("xenon", 0xBFE2FF)

    public static let all: [ColorToken] = [
        asphalt, tarmac, concrete, curb, seam, chalk, dust, gravel,
        sodium, sodiumDim, brake, go, xenon,
    ]
}

public extension Color {
    static let asphalt = Palette.asphalt.color
    static let tarmac = Palette.tarmac.color
    static let concrete = Palette.concrete.color
    static let curb = Palette.curb.color
    static let seam = Palette.seam.color
    static let chalk = Palette.chalk.color
    static let dust = Palette.dust.color
    static let gravel = Palette.gravel.color
    static let sodium = Palette.sodium.color
    static let sodiumDim = Palette.sodiumDim.color
    static let brake = Palette.brake.color
    static let go = Palette.go.color
    static let xenon = Palette.xenon.color

    /// A 24-bit sRGB value. Feature code uses this only for paint colors (a car's `color_hex`).
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }

    /// A paint color from a `#RRGGBB` or `RRGGBB` string; `nil` if it does not parse.
    init?(paintHex: String) {
        let digits = paintHex.hasPrefix("#") ? String(paintHex.dropFirst()) : paintHex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(rgb: value)
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The two functional gradients plan 9.2 allows, and nothing else.
public enum Gradients {
    /// Scrim under text on video and photos: `asphalt` 0% to 70% over the bottom 35% of the frame.
    public static let scrim = LinearGradient(
        stops: [
            .init(color: Color.asphalt.opacity(0), location: 0.65),
            .init(color: Color.asphalt.opacity(0.7), location: 1),
        ],
        startPoint: .top, endPoint: .bottom
    )

    /// Fade mask for the trailing edge of a horizontally scrolling strip. Use as `.mask`.
    public static let stripEdge = LinearGradient(
        stops: [
            .init(color: .black, location: 0.9),
            .init(color: .black.opacity(0), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing
    )
}
