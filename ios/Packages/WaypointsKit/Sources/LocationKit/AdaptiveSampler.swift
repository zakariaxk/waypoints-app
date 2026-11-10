import Core
import Foundation

/// Send-rate policy from plan section 3.3. Pure value type; `LiveLocationService` owns one.
public struct AdaptiveSampler: Sendable {
    public enum Mode: String, Sendable, Hashable, CaseIterable { case driving, slow, stationary }

    /// Speeds in meters per second.
    static let drivingSpeed = 5.0
    static let movingSpeed = 1.0
    /// Fixes arrive at about 1 Hz, so the driving gate has a little slack.
    static let drivingInterval: TimeInterval = 0.9
    static let slowInterval: TimeInterval = 3

    private var lastEmitted: Date?
    private(set) var mode: Mode?

    public init() {}

    static func mode(speed: Double, stationary: Bool) -> Mode {
        if stationary { return .stationary }
        if speed >= drivingSpeed { return .driving }
        if speed >= movingSpeed { return .slow }
        // Below walking pace but Core Location has not declared stationary yet: treat as slow.
        return .slow
    }

    /// Decides whether this fix is sent. Stationary sends one sample on entry, then nothing until
    /// movement resumes; the realtime heartbeat keeps the connection alive meanwhile.
    mutating func admit(_ sample: LocationSample) -> Mode? {
        let next = Self.mode(speed: sample.speed, stationary: sample.isStationary)
        defer { mode = next }
        let changed = next != mode
        switch next {
        case .stationary:
            guard changed else { return nil }
        case .driving, .slow:
            let interval = next == .driving ? Self.drivingInterval : Self.slowInterval
            if !changed, let lastEmitted, sample.timestamp.timeIntervalSince(lastEmitted) < interval { return nil }
        }
        lastEmitted = sample.timestamp
        return next
    }

    mutating func reset() { lastEmitted = nil; mode = nil }
}
