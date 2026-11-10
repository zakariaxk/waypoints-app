import Foundation

/// `profiles`, the owner's `privacy_settings` (read only; writes go through `GatewayService`),
/// and `device_tokens`. Section 5.1.
public protocol ProfileRepository: Sendable {
    func myProfile() async throws -> Profile
    func profile(_ id: UserID) async throws -> Profile
    func profile(handle: String) async throws -> Profile?
    func profiles(_ ids: [UserID]) async throws -> [Profile]
    func profile(uid: RealtimeUID) async throws -> Profile?
    func search(_ query: String, limit: Int) async throws -> [Profile]
    func isHandleAvailable(_ handle: String) async throws -> Bool
    @discardableResult func updateMyProfile(_ update: ProfileUpdate) async throws -> Profile
    func acceptTerms() async throws
    func myPrivacySettings() async throws -> PrivacySettings
    func registerDeviceToken(_ apnsToken: String, environment: APNsEnvironment) async throws
    func removeDeviceToken(_ apnsToken: String) async throws
    func notificationPrefs() async throws -> NotificationPrefs
    func setNotificationPrefs(_ prefs: NotificationPrefs) async throws
    /// Emits the signed-in user's profile whenever it changes.
    func myProfileChanges() async -> AsyncStream<Profile>
}
