import AppShell
import DesignSystem
import PushKitBridge
import SwiftUI
import UIKit

@main
struct WaypointsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var shell = CompositionRoot.makeShell()

    var body: some Scene {
        WindowGroup {
            AppShellView(shell: shell)
                .task { await LaunchActions.run(shell: shell) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MetricsCollector.start()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushKitBridge.didRegister(deviceToken: deviceToken)
    }
}
