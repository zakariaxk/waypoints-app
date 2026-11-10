import Foundation

/// Supabase Auth (implemented by `Backend`). Section 10.2 O1, 10.9 S5.
public protocol AuthService: Sendable {
    /// Current session, then every change. `nil` means signed out.
    func sessions() async -> AsyncStream<AuthSession?>
    func currentSession() async -> AuthSession?
    /// A valid access token, refreshed if needed. Used by `RealtimeClient` and `GatewayAPI`.
    func accessToken() async throws -> String
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession
    func sendEmailCode(to email: String) async throws
    func verifyEmailCode(_ code: String, email: String) async throws -> AuthSession
    /// Marks onboarding done for the current session (after O2 and X2).
    func completeOnboarding() async throws
    func signOut() async throws
    /// Deletes the account and everything it owns, then signs out.
    func deleteAccount() async throws
}
