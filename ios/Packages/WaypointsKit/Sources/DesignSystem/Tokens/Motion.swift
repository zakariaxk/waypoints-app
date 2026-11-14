import SwiftUI

/// Motion tokens (plan 9.5). With Reduce Motion on, every transition becomes a 0.2 s crossfade,
/// markers jump, loops stop; use `View.motion(_:value:)` or `Motion.resolved(_:reduceMotion:)`.
public enum Motion: String, Sendable, CaseIterable, Identifiable {
    /// Presses, toggles, chip selection, row highlight.
    case quick
    /// Content changes, expanding rows, tab content.
    case standard
    /// Sheet detents, peek cards rising from a marker.
    case sheet
    /// Only: the Showdown winner settling, a spot joining the collection, a marker icon unlocking.
    case win

    public var id: String { rawValue }

    public var animation: Animation {
        switch self {
        case .quick: .snappy(duration: 0.22, extraBounce: 0)
        case .standard: .smooth(duration: 0.35)
        case .sheet: .spring(duration: 0.45, bounce: 0.12)
        case .win: .bouncy(duration: 0.5, extraBounce: 0.1)
        }
    }

    /// A marker moving between two position fixes, so motion is continuous.
    public static func travel(interval: TimeInterval) -> Animation { .linear(duration: interval) }

    /// The Reduce Motion replacement for every transition.
    public static let crossfade: Animation = .easeInOut(duration: Timing.crossfade)

    public func resolved(reduceMotion: Bool) -> Animation {
        reduceMotion ? Motion.crossfade : animation
    }
}

/// Durations that are not animation curves.
public enum Timing {
    /// MapKit camera animation for recenter and focus on selection.
    public static let camera: TimeInterval = 0.6
    /// Image load fade and the Reduce Motion crossfade.
    public static let crossfade: TimeInterval = 0.2
    /// Toasts stay this long.
    public static let toast: TimeInterval = 3
    /// Skeletons appear only after loading has taken this long.
    public static let skeletonDelay: TimeInterval = 0.3
    /// The live ring on a moving friend pulses once per this period.
    public static let livePulse: TimeInterval = 2
    /// Step of the 3-dot loading indicator.
    public static let loadingStep: TimeInterval = 0.3
    /// The double-tap like heart stays this long before it fades.
    public static let likeHeart: TimeInterval = 0.6
    /// The Showdown winner holds full screen this long before the next pair.
    public static let winHold: TimeInterval = 0.5
}

public extension View {
    /// Animates `value` changes with a motion token, honoring Reduce Motion.
    func motion<V: Equatable>(_ token: Motion, value: V) -> some View {
        modifier(MotionModifier(token: token, value: value))
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let token: Motion
    let value: V

    func body(content: Content) -> some View {
        content.animation(token.resolved(reduceMotion: reduceMotion), value: value)
    }
}

/// `withAnimation` for a token. Pass the environment's Reduce Motion value.
@MainActor
public func withMotion<Result>(_ token: Motion, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(token.resolved(reduceMotion: reduceMotion), body)
}
