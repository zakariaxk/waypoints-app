import Core
import UIKit
import UserNotifications

/// APNs registration and notification taps (plan 10.9 S3, 10.2). Permission is asked by the
/// features at their moments (first RSVP, first friend request, meets-nearby switch) through
/// the system prompt; this module notices the grant, registers the device token with the
/// backend, and turns taps into routes.
public enum PushKitBridge: FeatureModule {
    public static let isAvailable = true

    @MainActor static var env: AppEnvironment?
    @MainActor static let delegate = Delegate()

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        self.env = env
        UNUserNotificationCenter.current().delegate = delegate
        Task {
            for await session in await env.auth.sessions() where session != nil {
                await registerIfAllowed()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await registerIfAllowed() }
        }
    }

    @MainActor
    static func registerIfAllowed() async {
        let allowed = await withCheckedContinuation { c in
            UNUserNotificationCenter.current().getNotificationSettings { s in
                c.resume(returning: s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
            }
        }
        if allowed { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Called by the app delegate with the APNs token.
    @MainActor
    public static func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = APNsEnvironment.sandbox
        #else
        let environment = APNsEnvironment.production
        #endif
        guard let env else { return }
        Task { try? await env.profiles.registerDeviceToken(token, environment: environment) }
    }

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
            -> UNNotificationPresentationOptions { [.banner, .sound] }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            guard let raw = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: raw) else { return }
            await MainActor.run { UIApplication.shared.open(url) }
        }
    }
}
