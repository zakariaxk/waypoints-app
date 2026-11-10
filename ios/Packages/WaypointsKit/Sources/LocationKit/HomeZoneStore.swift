import Core
import Foundation
import Security

/// Home zones as one JSON blob in a device-only Keychain item (plan section 2.5: zone centres
/// never leave the phone except over TLS to the gateway at connect).
struct HomeZoneStore: Sendable {
    let service: String
    private let account = "home-zones"

    init(service: String = "app.waypoints.location") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func load() -> [HomeZone] {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([HomeZone].self, from: data)) ?? []
    }

    func save(_ zones: [HomeZone]) throws {
        let data = try JSONEncoder().encode(zones)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WaypointsError.server("keychain \(status)") }
    }
}
