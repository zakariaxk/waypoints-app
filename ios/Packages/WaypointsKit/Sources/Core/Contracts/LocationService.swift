import Foundation

/// Implemented by `LocationKit` (plan section 4.3).
public protocol LocationService: Sendable {
    func samples() async -> AsyncStream<LocationSample>
    func authorization() async -> AsyncStream<LocationAuthorization>
    func requestWhenInUse() async
    func requestAlways() async
    func setSharing(_ on: Bool) async
}
