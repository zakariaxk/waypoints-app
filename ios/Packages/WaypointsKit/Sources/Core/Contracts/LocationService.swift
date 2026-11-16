import Foundation

/// A feature that keeps location alive in the background without the
/// "Keep sharing when the app is closed" setting (PRV-12).
public enum LocationActivity: Sendable {
    case navigation
    case convoy
}

/// Implemented by `LocationKit` (plan section 4.3).
public protocol LocationService: Sendable {
    func samples() async -> AsyncStream<LocationSample>
    func authorization() async -> AsyncStream<LocationAuthorization>
    func requestWhenInUse() async
    func requestAlways() async
    func setSharing(_ on: Bool) async
    /// PRV-12: marks an activity that holds background location without Always
    /// authorization and suspends the 5-minute parked stop (navigation, even paused,
    /// or a live convoy).
    func setActive(_ activity: LocationActivity, _ active: Bool) async
    /// Saved home zones (stored on this device only, section 2.5): the current list, then every change.
    func homeZones() async -> AsyncStream<[HomeZone]>
    /// Replaces the saved zones. Throws `WaypointsError.invalid("home_zones")` past `HomeZone.maximumCount`.
    func setHomeZones(_ zones: [HomeZone]) async throws
}
