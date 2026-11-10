import Core
import Foundation

/// `waypoints://` and universal links (section 10.10, X3). Both use the same paths:
///
///     profile/<uuid>   car/<uuid>   meet/<uuid>   team/<uuid>   listing/<uuid>   post/<uuid>
///     invite/team/<code>            invite/convoy/<code>
public enum DeepLink {
    public static func route(from url: URL) -> Route? {
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "waypoints", let host = url.host(), !host.isEmpty { parts.insert(host, at: 0) }
        guard parts.count >= 2 else { return nil }
        let value = parts[1]
        switch parts[0] {
        case "profile": return UserID(string: value).map(Route.profile)
        case "car": return CarID(string: value).map(Route.car)
        case "meet": return MeetID(string: value).map(Route.meet)
        case "team": return TeamID(string: value).map(Route.team)
        case "listing": return ListingID(string: value).map(Route.listing)
        case "post": return PostID(string: value).map(Route.post)
        case "invite" where parts.count >= 3:
            switch value {
            case "team": return .joinTeam(code: parts[2])
            case "convoy": return .joinConvoy(code: parts[2])
            default: return nil
            }
        default: return nil
        }
    }

    public static func url(for route: Route) -> URL? {
        let path: String? = switch route {
        case .profile(let id): "profile/\(id)"
        case .car(let id): "car/\(id)"
        case .meet(let id): "meet/\(id)"
        case .team(let id): "team/\(id)"
        case .listing(let id): "listing/\(id)"
        case .post(let id): "post/\(id)"
        case .joinTeam(let code): "invite/team/\(code)"
        case .joinConvoy(let code): "invite/convoy/\(code)"
        default: nil
        }
        return path.flatMap { URL(string: "waypoints://\($0)") }
    }
}
