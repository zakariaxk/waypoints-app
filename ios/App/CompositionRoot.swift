import AppShell
import Backend
import Core
import Foundation
import GatewayAPI
import LocationKit
import RealtimeClient
import SafetyKit
import SwiftUI
import VehicleCatalog

/// Builds `AppEnvironment` from each infrastructure module's factory. Every factory returns the
/// preview implementation until its owning package replaces it (plan section 12, W0-A).
@MainActor
enum CompositionRoot {
    static func makeShell() -> ShellModel {
        #if DEBUG
        if LaunchOptions.current.preview {
            // -wp-preview (PRD 7.1): no backend, the realistic preview seed, signed in.
            let shell = ShellModel(makeEnvironment: { PreviewEnvironment.make(signedIn: true, router: $0) })
            registerDebugScreens(in: shell)
            return shell
        }
        #endif
        let shell = ShellModel(makeEnvironment: makeEnvironment(router:))
        #if DEBUG
        registerDebugScreens(in: shell)
        #endif
        return shell
    }

    #if DEBUG
    /// Debug screens only the app target can build, because they come from infrastructure
    /// modules the shell does not import (`waypoints://debug/<name>`).
    private static func registerDebugScreens(in shell: ShellModel) {
        let safety = shell.environment.safety
        for name in ["terms", "terms-gate"] {
            shell.registry.registerDebugScreen(name) { AnyView(TermsGate(safety: safety) {}) }
        }
    }
    #endif

    static func makeEnvironment(router: any Router) -> AppEnvironment {
        let config = loadConfig()
        let backend = Backend.makeLive(config: config)
        let location = LocationKit.makeLive(config: config)
        return AppEnvironment(
            auth: backend.auth,
            profiles: backend.profiles,
            garage: backend.garage,
            friends: backend.friends,
            meets: backend.meets,
            reports: backend.reports,
            teams: backend.teams,
            messages: backend.messages,
            posts: backend.posts,
            showdown: backend.showdown,
            market: backend.market,
            spots: backend.spots,
            roads: backend.roads,
            progress: backend.progress,
            media: backend.media,
            realtime: RealtimeClient.makeLive(config: config, auth: backend.auth, location: location),
            location: location,
            gateway: GatewayAPI.makeLive(config: config, auth: backend.auth),
            catalog: VehicleCatalog.makeLive(config: config),
            safety: SafetyKit.makeLive(config: config, auth: backend.auth, profiles: backend.profiles),
            router: router,
            activity: backend.activity
        )
    }

    /// Reads the values `Config.xcconfig` injects into Info.plist. Missing or empty values fall
    /// back to the local defaults so a fresh clone runs.
    static func loadConfig(bundle: Bundle = .main) -> AppConfig {
        func string(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        let local = AppConfig.local
        return AppConfig(
            supabaseURL: string("WPSupabaseURL").flatMap(URL.init(string:)) ?? local.supabaseURL,
            supabaseAnonKey: string("WPSupabaseAnonKey") ?? local.supabaseAnonKey,
            gatewayURL: string("WPGatewayURL").flatMap(URL.init(string:)) ?? local.gatewayURL,
            appVersion: string("CFBundleShortVersionString") ?? local.appVersion,
            linkHost: string(AppConfig.linkHostInfoKey).flatMap { $0.contains("$(") ? nil : $0.lowercased() }
        )
    }
}
