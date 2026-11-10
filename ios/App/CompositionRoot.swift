import AppShell
import Backend
import Core
import Foundation
import GatewayAPI
import LocationKit
import RealtimeClient
import SafetyKit
import VehicleCatalog

/// Builds `AppEnvironment` from each infrastructure module's factory. Every factory returns the
/// preview implementation until its owning package replaces it (plan section 12, W0-A).
@MainActor
enum CompositionRoot {
    static func makeShell() -> ShellModel {
        ShellModel(makeEnvironment: makeEnvironment(router:))
    }

    static func makeEnvironment(router: any Router) -> AppEnvironment {
        let config = loadConfig()
        let backend = Backend.makeLive(config: config)
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
            realtime: RealtimeClient.makeLive(config: config, auth: backend.auth),
            location: LocationKit.makeLive(config: config),
            gateway: GatewayAPI.makeLive(config: config, auth: backend.auth),
            catalog: VehicleCatalog.makeLive(config: config),
            safety: SafetyKit.makeLive(config: config),
            router: router
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
            appVersion: string("CFBundleShortVersionString") ?? local.appVersion
        )
    }
}
