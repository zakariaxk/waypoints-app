import CoreLocation
import Core

/// Owns the `CLLocationManager` used only for authorization requests and changes. Main actor,
/// because Core Location delivers delegate callbacks on the thread that created the manager.
@MainActor
final class AuthorizationMonitor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onChange: @Sendable (LocationAuthorization) -> Void

    init(onChange: @escaping @Sendable (LocationAuthorization) -> Void) {
        self.onChange = onChange
        super.init()
        manager.delegate = self
    }

    var current: LocationAuthorization { Self.map(manager.authorizationStatus) }
    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onChange(Self.map(manager.authorizationStatus))
    }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        @unknown default: .denied
        }
    }
}
