import SwiftUI

// DesignSystem: docs/PLAN.md section 9 as code.
//
//   Tokens/      color, type, spacing, shape, depth, motion, haptics, symbols
//   Components/  every component in 9.9
//   MapIcons/    silhouettes, report badges, meet pins, VehicleMarker, ClusterMarker
//   Support/     image cache, contrast math
//   Gallery/     the debug gallery and contrast audit
//
// Imports nothing from the package. Feature code uses these tokens and never writes a literal
// color, font size, radius, spacing, or duration.

public enum DesignSystem {
    /// Registers the embedded readout face. Called lazily by the first readout font; calling it
    /// at launch only moves that work earlier.
    public static func prepare() {
        _ = ReadoutFace.postScriptName
    }
}
