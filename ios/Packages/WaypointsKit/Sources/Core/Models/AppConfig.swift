import Foundation

/// Values from `ios/App/Config.xcconfig`, read by the composition root and handed to each
/// infrastructure module's `makeLive(config:)`.
public struct AppConfig: Sendable, Hashable {
    public var supabaseURL: URL
    public var supabaseAnonKey: String
    public var gatewayURL: URL
    public var appVersion: String
    public init(supabaseURL: URL, supabaseAnonKey: String, gatewayURL: URL, appVersion: String) {
        self.supabaseURL = supabaseURL; self.supabaseAnonKey = supabaseAnonKey
        self.gatewayURL = gatewayURL; self.appVersion = appVersion
    }

    /// Local defaults: `supabase start` and `go run ./cmd/gateway`.
    public static let local = AppConfig(
        supabaseURL: URL(string: "http://127.0.0.1:54321")!,
        supabaseAnonKey: "",
        gatewayURL: URL(string: "http://127.0.0.1:8080")!,
        appVersion: "0.0.0"
    )
}
