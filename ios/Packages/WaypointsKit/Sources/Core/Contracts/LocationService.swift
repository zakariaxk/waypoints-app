import Foundation

/// Implemented by `LocationKit` (plan section 4.3).
public protocol LocationService: Sendable {
    func samples() async -> AsyncStream<LocationSample>
    func authorization() async -> AsyncStream<LocationAuthorization>
    func requestWhenInUse() async
    func requestAlways() async
    func setSharing(_ on: Bool) async
    /// Saved home zones (stored on this device only, section 2.5): the current list, then every change.
    func homeZones() async -> AsyncStream<[HomeZone]>
    /// Replaces the saved zones. Throws `WaypointsError.invalid("home_zones")` past `HomeZone.maximumCount`.
    func setHomeZones(_ zones: [HomeZone]) async throws
}
