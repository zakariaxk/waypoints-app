import SwiftUI

// Stub from W0-A: the minimum of section 9 that `AppShell` needs (colors from 9.2, two type
// tokens from 9.3, spacing from 9.4). W0-D replaces this file with the full design system and
// keeps these names, or updates `AppShell` in the same commit.

public extension Color {
    static let asphalt = Color(rgb: 0x0D0D0E)
    static let tarmac = Color(rgb: 0x161617)
    static let concrete = Color(rgb: 0x202022)
    static let curb = Color(rgb: 0x2B2B2E)
    static let seam = Color(rgb: 0x37373B)
    static let chalk = Color(rgb: 0xF3F1EC)
    static let dust = Color(rgb: 0xA8A6A0)
    static let gravel = Color(rgb: 0x86847F)
    static let sodium = Color(rgb: 0xFFB224)
    static let sodiumDim = Color(rgb: 0x3A2A0A)
    static let brake = Color(rgb: 0xFF4B3A)
    static let go = Color(rgb: 0x34D17C)
    static let xenon = Color(rgb: 0xBFE2FF)

    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

/// Type tokens (section 9.3). Each scales with Dynamic Type.
public enum TypeToken: Sendable, CaseIterable {
    case display, title, body, foot

    public var font: Font {
        switch self {
        case .display: .system(.title, weight: .bold).width(.expanded)
        case .title: .system(.title3, weight: .semibold).width(.expanded)
        case .body: .system(.body)
        case .foot: .system(.footnote)
        }
    }
}

public extension View {
    func typeStyle(_ token: TypeToken) -> some View { font(token.font) }
}

/// Spacing tokens (section 9.4).
public enum Space {
    public static let s2: CGFloat = 2
    public static let s4: CGFloat = 4
    public static let s8: CGFloat = 8
    public static let s12: CGFloat = 12
    public static let s16: CGFloat = 16
    public static let s20: CGFloat = 20
    public static let s24: CGFloat = 24
    public static let s32: CGFloat = 32
    public static let s48: CGFloat = 48
    /// Screen side margin.
    public static let margin: CGFloat = 20
}
