import Foundation

/// Values from `ios/App/Config.xcconfig`, read by the composition root and handed to each
/// infrastructure module's `makeLive(config:)`.
public struct AppConfig: Sendable, Hashable {
    public var supabaseURL: URL
    public var supabaseAnonKey: String
    public var gatewayURL: URL
    public var appVersion: String
    /// Universal-link host (`LINK_HOST`, Info.plist `WPLinkHost`), for example
    /// `waypoints.github.io`. Nil until the owner picks one; links then stay `waypoints://`.
    public var linkHost: String?
    public init(supabaseURL: URL, supabaseAnonKey: String, gatewayURL: URL, appVersion: String, linkHost: String? = nil) {
        self.supabaseURL = supabaseURL; self.supabaseAnonKey = supabaseAnonKey
        self.gatewayURL = gatewayURL; self.appVersion = appVersion
        self.linkHost = linkHost
    }

    /// Info.plist key the composition root, `DeepLink`, and Settings read the link host from.
    public static let linkHostInfoKey = "WPLinkHost"

    /// Where the app target's MetricKit subscriber keeps the last payloads (OBS-2), read by the
    /// debug screen in Settings. Application Support/MetricKit/.
    public static var metricKitDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "MetricKit", directoryHint: .isDirectory)
    }
    public static var lastDiagnosticPayloadURL: URL {
        metricKitDirectory.appending(path: "last-diagnostic.json", directoryHint: .notDirectory)
    }
    public static var lastMetricPayloadURL: URL {
        metricKitDirectory.appending(path: "last-metrics.json", directoryHint: .notDirectory)
    }

    /// Local defaults: `supabase start` and `go run ./cmd/gateway`.
    public static let local = AppConfig(
        supabaseURL: URL(string: "http://127.0.0.1:54321")!,
        supabaseAnonKey: "",
        gatewayURL: URL(string: "http://127.0.0.1:8080")!,
        appVersion: "0.0.0"
    )
}
