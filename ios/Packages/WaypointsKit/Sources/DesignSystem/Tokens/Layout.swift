import SwiftUI

/// Spacing tokens (plan 9.4).
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
    /// Row vertical padding.
    public static let rowPadding: CGFloat = 12
    /// Gap between unrelated groups.
    public static let groupGap: CGFloat = 32

    public static let all: [(String, CGFloat)] = [
        ("s2", s2), ("s4", s4), ("s8", s8), ("s12", s12), ("s16", s16),
        ("s20", s20), ("s24", s24), ("s32", s32), ("s48", s48),
    ]
}

/// Corner radii (plan 9.4). Nested corners are concentric: use `Radius.inner(of:padding:)`.
public enum Radius {
    /// Chips, small thumbnails.
    public static let r6: CGFloat = 6
    /// Inputs, rows, buttons.
    public static let r12: CGFloat = 12
    /// Media, cards over the map.
    public static let r20: CGFloat = 20
    /// Top corners of sheets.
    public static let r28: CGFloat = 28

    public static let all: [(String, CGFloat)] = [("r6", r6), ("r12", r12), ("r20", r20), ("r28", r28)]

    public static func inner(of outer: CGFloat, padding: CGFloat) -> CGFloat { max(0, outer - padding) }
}

/// Fixed component and marker sizes (plan 9.4, 9.8, 9.9).
public enum Size {
    /// Minimum hit target, markers included.
    public static let hitTarget: CGFloat = 44
    /// Buttons and fields.
    public static let control: CGFloat = 52
    /// Minimum row height.
    public static let row: CGFloat = 56
    public static let chip: CGFloat = 32
    /// Paint bar on car rows.
    public static let paintBar: CGFloat = 3
    /// Inline silhouette in `CarBadge` at the default text size.
    public static let inlineSilhouette: CGFloat = 20
    /// Thin bar under a `Readout`.
    public static let rangeBar: CGFloat = 4
    /// Underline of `SegmentedSwitch`.
    public static let underline: CGFloat = 2
    /// The heart that scales in at the touch point on a double-tap like.
    public static let likeHeart: CGFloat = 88

    public enum Marker {
        public static let you: CGFloat = 44
        public static let friend: CGFloat = 40
        public static let stranger: CGFloat = 28
        public static let approximateRing: CGFloat = 56
        public static let cluster: CGFloat = 44
        public static let reportBadge: CGFloat = 32
        public static let reportGlyph: CGFloat = 24
        public static let meetPin: CGFloat = 40
        /// Keyline and ring widths.
        public static let keyline: CGFloat = 2
        public static let ring: CGFloat = 2
        public static let innerStroke: CGFloat = 1
        public static let selectedScale: CGFloat = 1.15
    }
}

/// Opacity tokens, so feature code never writes a bare fraction.
public enum Opacity {
    /// Approximate-location silhouettes.
    public static let approximate: Double = 0.6
    /// Trails behind moving markers.
    public static let trail: Double = 0.5
    /// Stale markers over 5 minutes old are desaturated by this much.
    public static let staleDesaturation: Double = 0.5
    /// Pressed buttons scale to this.
    public static let pressedScale: CGFloat = 0.96
    /// Text-only controls while pressed.
    public static let pressed: Double = 0.6
    /// Unlit steps of the loading indicator.
    public static let inactive: Double = 0.4
}

/// Depth (plan 9.4). Surfaces separate by fill step and a hairline; only things floating over
/// the map cast a shadow.
public enum Depth {
    public static let shadowColor = Color.black.opacity(0.45)
    public static let shadowRadius: CGFloat = 8   // SwiftUI radius is half the blur: blur 16
    public static let shadowY: CGFloat = 4
}

public extension View {
    /// The one shadow: for controls, cards, and markers floating over the map.
    func mapShadow() -> some View {
        shadow(color: Depth.shadowColor, radius: Depth.shadowRadius, x: 0, y: Depth.shadowY)
    }

    /// `.regularMaterial`, used only for controls and the sheet over the map (plan 9.4).
    func overMapMaterial<S: Shape>(in shape: S) -> some View {
        background(.regularMaterial, in: shape)
    }
}

/// A `seam` hairline exactly one physical pixel thick.
public struct Hairline: View {
    @Environment(\.displayScale) private var displayScale
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(Color.seam)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}
