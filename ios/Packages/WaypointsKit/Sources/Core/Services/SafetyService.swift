import Foundation

/// X2/ACC-6: the terms in force. When the six rules or the legal text change, bump
/// `version` and set `effectiveAt` to the day the new text ships; agreement recorded before
/// then is an older version and `needsTermsAcceptance()` shows the gate again.
public enum Terms {
    /// Terms version users are agreeing to now.
    public static let version = 1
    /// When `version` took effect. `Profile.acceptedTermsAt` earlier than this is stale.
    public static let effectiveAt = Date.distantPast
}

public extension Profile {
    /// X2/ACC-6: agreed to the terms now in force, not an older version.
    var acceptedCurrentTerms: Bool { acceptedTermsAt.map { $0 >= Terms.effectiveAt } ?? false }
}

/// Report, block, text filter, terms gate (section 10.10), implemented by `SafetyKit`.
public protocol SafetyService: Sendable {
    func report(_ target: ContentRef, reason: ContentReportReason, note: String?) async throws
    /// Targets the signed-in user has reported (SAFE-3): a reported item disappears for its reporter.
    func reportedTargets() async throws -> Set<ContentRef>
    func block(_ user: UserID) async throws
    func unblock(_ user: UserID) async throws
    func blockedUsers() async throws -> [Profile]
    /// Current blocked set, then every change, so features can hide content immediately.
    func blockedChanges() async -> AsyncStream<Set<UserID>>
    /// Checks user-entered text against the bundled word list before posting.
    func check(_ text: String) async -> TextCheck
    /// True when the user has not accepted the current terms (X2).
    func needsTermsAcceptance() async -> Bool
    func acceptTerms() async throws
}
