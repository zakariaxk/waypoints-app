import AppShell
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
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushKitBridge.didRegister(deviceToken: deviceToken)
    }
}
