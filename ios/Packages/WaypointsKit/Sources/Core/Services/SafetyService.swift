import Foundation

/// Report, block, text filter, terms gate (section 10.10), implemented by `SafetyKit`.
public protocol SafetyService: Sendable {
    func report(_ target: ContentRef, reason: ContentReportReason, note: String?) async throws
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
