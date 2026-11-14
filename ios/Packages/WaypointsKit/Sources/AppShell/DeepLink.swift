import Core
import Foundation

/// `waypoints://` and universal links (section 10.10, X3). Both use the same paths:
///
///     profile/<uuid>   car/<uuid>   meet/<uuid>   team/<uuid>   listing/<uuid>   post/<uuid>
///     invite/team/<code>            invite/convoy/<code>
///
/// Universal links are `https://<LINK_HOST>/<path>`. The host comes from Info.plist
/// (`WPLinkHost`, set from `LINK_HOST` in Config.xcconfig). With no host configured,
/// `url(for:)` returns the `waypoints://` form.
public enum DeepLink {
    /// The configured universal-link host, lowercased, or nil.
    public static var linkHost: String? { Route.linkHost }

    public static func route(from url: URL) -> Route? { route(from: url, host: linkHost) }

    public static func route(from url: URL, host linkHost: String?) -> Route? {
        var parts = url.pathComponents.filter { $0 != "/" }
        switch url.scheme?.lowercased() {
        case "waypoints":
            if let host = url.host(), !host.isEmpty { parts.insert(host, at: 0) }
        case "https":
            guard let linkHost, url.host()?.lowercased() == linkHost else { return nil }
        default:
            return nil
        }
        guard parts.count >= 2 else { return nil }
        let value = parts[1]
        switch parts[0] {
        case "profile": return UserID(string: value).map(Route.profile)
        case "car": return CarID(string: value).map(Route.car)
        case "meet": return MeetID(string: value).map(Route.meet)
        case "team": return TeamID(string: value).map(Route.team)
        case "listing": return ListingID(string: value).map(Route.listing)
        case "post": return PostID(string: value).map(Route.post)
        case "thread": return ThreadID(string: value).map(Route.thread)
        case "channel": return ChannelID(string: value).map(Route.channel)
        case "invite" where parts.count >= 3:
            switch value {
            case "team": return .joinTeam(code: parts[2])
            case "convoy": return .joinConvoy(code: parts[2])
            default: return nil
            }
        default: return nil
        }
    }

    public static func url(for route: Route) -> URL? { url(for: route, host: linkHost) }

    /// The https form on `host` when one is configured, else `waypoints://`.
    public static func url(for route: Route, host: String?) -> URL? {
        route.shareURL(host: host)
    }
}
