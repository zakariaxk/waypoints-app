import SwiftUI

/// Haptic tokens (plan 9.6). Never on things that happen remotely and never on scroll.
public enum Haptic: String, Sendable, CaseIterable, Identifiable {
    /// Moving through picker values, year strip, mod toggles, shift points on the dyno scrub.
    case tick
    /// Selecting a marker, sending a message.
    case tap
    /// Sheet reaching a detent, a swipe card passing its commit threshold.
    case set
    /// Showdown choice committed, race launch.
    case thud
    /// Report posted, meet created, listing published, RSVP saved.
    case done
    /// Off route, hazard ahead (navigation only).
    case warn
    /// A submit that failed.
    case fail

    public var id: String { rawValue }

    public var feedback: SensoryFeedback {
        switch self {
        case .tick: .selection
        case .tap: .impact(weight: .light)
        case .set: .impact(flexibility: .soft)
        case .thud: .impact(weight: .heavy)
        case .done: .success
        case .warn: .warning
        case .fail: .error
        }
    }
}

public extension View {
    /// Fires a haptic token whenever `trigger` changes.
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger)
    }

    /// Fires a haptic token when `condition` returns true for a change of `trigger`.
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
        sensoryFeedback(haptic.feedback, trigger: trigger, condition: condition)
    }
}
