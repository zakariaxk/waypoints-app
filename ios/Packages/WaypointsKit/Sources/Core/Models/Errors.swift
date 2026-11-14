import Foundation

/// Errors every repository and service may throw. Messages shown to people are written by
/// features (section 9.10); these cases only say what happened.
public enum WaypointsError: Error, Sendable, Hashable {
    case notSignedIn
    case notFound
    case offline
    case forbidden
    case rateLimited
    case suspended                 // the account is suspended (SAFE-7)
    case conflict(String)          // e.g. handle taken
    case invalid(String)           // a field failed validation; associated value names it
    case server(String)
}
