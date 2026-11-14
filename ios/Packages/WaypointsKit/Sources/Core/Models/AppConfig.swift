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

/// LINK-3: the link to share for a route. Lives in Core so features (which cannot import
/// AppShell) share the same form `DeepLink` parses: `https://<LINK_HOST>/<path>` when a host
/// is configured, else `waypoints://<path>`.
public extension Route {
    /// The configured universal-link host from Info.plist, lowercased, or nil.
    static let linkHost: String? = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: AppConfig.linkHostInfoKey) as? String else { return nil }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return host.isEmpty || host.contains("$(") ? nil : host
    }()

    /// The shareable path, for routes that have one.
    var linkPath: String? {
        switch self {
        case .profile(let id): "profile/\(id)"
        case .car(let id): "car/\(id)"
        case .meet(let id): "meet/\(id)"
        case .team(let id): "team/\(id)"
        case .listing(let id): "listing/\(id)"
        case .post(let id): "post/\(id)"
        case .thread(let id): "thread/\(id)"
        case .channel(let id): "channel/\(id)"
        case .help(let id): "help/\(id)"
        case .joinTeam(let code): "invite/team/\(code)"
        case .joinConvoy(let code): "invite/convoy/\(code)"
        default: nil
        }
    }

    /// Use this in every share sheet.
    var shareURL: URL? { shareURL(host: Self.linkHost) }

    func shareURL(host: String?) -> URL? {
        guard let linkPath else { return nil }
        if let host { return URL(string: "https://\(host)/\(linkPath)") }
        return URL(string: "waypoints://\(linkPath)")
    }

    /// Parses a link path (the inverse of `linkPath`), given as its components:
    /// `["profile", "<uuid>"]`, `["invite", "convoy", "<code>"]`. HELP-4, X3.
    init?(pathComponents parts: [String]) {
        guard parts.count >= 2 else { return nil }
        let value = parts[1]
        let route: Route?
        switch parts[0].lowercased() {
        case "profile": route = UserID(string: value).map(Route.profile)
        case "car": route = CarID(string: value).map(Route.car)
        case "meet": route = MeetID(string: value).map(Route.meet)
        case "team": route = TeamID(string: value).map(Route.team)
        case "listing": route = ListingID(string: value).map(Route.listing)
        case "post": route = PostID(string: value).map(Route.post)
        case "thread": route = ThreadID(string: value).map(Route.thread)
        case "channel": route = ChannelID(string: value).map(Route.channel)
        case "help": route = HelpRequestID(string: value).map(Route.help)
        case "invite" where parts.count >= 3 && !parts[2].isEmpty:
            switch value.lowercased() {
            case "team": route = .joinTeam(code: parts[2])
            case "convoy": route = .joinConvoy(code: parts[2])
            default: route = nil
            }
        default: route = nil
        }
        guard let route else { return nil }
        self = route
    }

    /// Parses `waypoints://<path>`, and `https://<host>/<path>` when `host` (lowercased) is
    /// given and matches. Every other URL returns nil.
    init?(url: URL, host linkHost: String?) {
        var parts = url.pathComponents.filter { $0 != "/" }
        switch url.scheme?.lowercased() {
        case "waypoints":
            if let host = url.host(), !host.isEmpty { parts.insert(host, at: 0) }
        case "https":
            guard let linkHost, url.host()?.lowercased() == linkHost else { return nil }
        default:
            return nil
        }
        self.init(pathComponents: parts)
    }
}
