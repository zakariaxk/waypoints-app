import Core
import Foundation

/// `waypoints://` and universal links (section 10.10, X3). Both use the same paths:
///
///     profile/<uuid>   car/<uuid>   meet/<uuid>   team/<uuid>   listing/<uuid>   post/<uuid>
///     thread/<uuid>    channel/<uuid>    help/<uuid>
///     invite/team/<code>            invite/convoy/<code>
///
/// Universal links are `https://<LINK_HOST>/<path>`. The host comes from Info.plist
/// (`WPLinkHost`, set from `LINK_HOST` in Config.xcconfig). With no host configured,
/// `url(for:)` returns the `waypoints://` form.
public enum DeepLink {
    /// The configured universal-link host, lowercased, or nil.
    public static var linkHost: String? { Route.linkHost }

    public static func route(from url: URL) -> Route? { route(from: url, host: linkHost) }

    /// Path parsing lives in Core (`Route.init(url:host:)`) so Activity links parse the same.
    public static func route(from url: URL, host linkHost: String?) -> Route? {
        Route(url: url, host: linkHost)
    }

    public static func url(for route: Route) -> URL? { url(for: route, host: linkHost) }

    /// The https form on `host` when one is configured, else `waypoints://`.
    public static func url(for route: Route, host: String?) -> URL? {
        route.shareURL(host: host)
    }
}
