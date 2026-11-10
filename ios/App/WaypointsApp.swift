import AppShell
import SwiftUI

@main
struct WaypointsApp: App {
    @State private var shell = CompositionRoot.makeShell()

    var body: some Scene {
        WindowGroup {
            AppShellView(shell: shell)
        }
    }
}
