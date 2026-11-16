import AuthenticationServices
import Core
import Foundation
import Supabase
import UIKit

/// Supabase Auth: Sign in with Apple (ID token + nonce), email one-time code, automatic
/// refresh (the SDK refreshes before expiry and `accessToken()` refreshes on demand),
/// sign-out (which first removes this phone's APNs token, NTF-5), and account deletion
/// through the `delete_account` RPC. Suspended accounts (SAFE-7) are signed out and
/// sign-in throws `WaypointsError.suspended`.
actor LiveAuth: AuthService {
    private let ctx: BackendContext
    private let fanout = Fanout<AuthSession?>()
    private var current: AuthSession?
    private var loaded = false
    /// Users whose profile has accepted terms, so later token refreshes skip the lookup.
    private var onboarded: Set<UUID> = []
    private var observer: Task<Void, Never>?

    init(ctx: BackendContext) {
        self.ctx = ctx
    }

    private func startObserving() {
        guard observer == nil else { return }
        let changes = ctx.client.auth.authStateChanges
        observer = Task { [weak self] in
            for await (event, session) in changes {
                guard let self else { return }
                await self.handle(event, session)
            }
        }
    }

    private func handle(_ event: AuthChangeEvent, _ session: Session?) async {
        switch event {
        case .signedOut, .userDeleted:
            await publish(nil)
        default:
            if let session {
                do {
                    if let made = try await makeSession(session) {
                        await publish(made)
                    } else {
                        try? await ctx.client.auth.signOut(scope: .local)
                        await publish(nil)
                    }
                    loaded = true
                } catch {
                    // The profile lookup failed (offline/flaky PostgREST): publish
                    // nothing rather than guessing — a nil here reads as signed out.
                    // Keep `loaded` false so the initial-session race stays open
                    // until an event produces a definitive state.
                }
            } else if event == .initialSession {
                await publish(nil)
                loaded = true
            }
        }
        if event == .signedOut || event == .userDeleted { loaded = true }
    }

    private func publish(_ session: AuthSession?) async {
        guard session != current || !loaded else { return }
        current = session
        await fanout.send(session)
    }

    /// `nil` when the account is suspended.
    private func makeSession(_ session: Session) async throws -> AuthSession? {
        let id = session.user.id
        var needsOnboarding = !onboarded.contains(id)
        if needsOnboarding {
            let flags = try await Self.accountFlags(ctx: ctx, id: id)
            if flags.suspended { return nil }
            if flags.acceptedTerms {
                onboarded.insert(id)
                needsOnboarding = false
            }
        }
        return AuthSession(userID: UserID(raw: id), email: session.user.email, accessToken: session.accessToken,
                           expiresAt: Date(timeIntervalSince1970: session.expiresAt), needsOnboarding: needsOnboarding)
    }

    private func waitForInitialState() async {
        startObserving()
        // The SDK emits `initialSession` right away; give it a moment on a cold start.
        for _ in 0..<40 where !loaded {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: AuthService

    func sessions() async -> AsyncStream<AuthSession?> {
        await waitForInitialState()
        return await fanout.subscribe(initial: .some(current))
    }

    func currentSession() async -> AuthSession? {
        await waitForInitialState()
        return current
    }

    func accessToken() async throws -> String {
        do {
            return try await ctx.client.auth.session.accessToken
        } catch {
            throw BackendContext.map(error)
        }
    }

    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        startObserving()
        let session = try await ctx.run {
            try await ctx.client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        }
        return try await finishSignIn(session)
    }

    func sendEmailCode(to email: String) async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@") else { throw WaypointsError.invalid("email") }
        try await ctx.run { try await ctx.client.auth.signInWithOTP(email: address, shouldCreateUser: true) }
    }

    func verifyEmailCode(_ code: String, email: String) async throws -> AuthSession {
        startObserving()
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = code.filter(\.isNumber)
        let response = try await ctx.run {
            try await ctx.client.auth.verifyOTP(email: address, token: token, type: .email)
        }
        guard let session = response.session else { throw WaypointsError.invalid("code") }
        return try await finishSignIn(session)
    }

    #if DEBUG
    /// Email and password sign-in for the `-wp-login` launch argument (PRD 7.1). Debug builds
    /// only; the composition root also refuses it unless Supabase is on a loopback address.
    func debugSignIn(email: String, password: String) async throws -> AuthSession {
        startObserving()
        let session = try await ctx.run {
            try await ctx.client.auth.signIn(email: email, password: password)
        }
        return try await finishSignIn(session)
    }
    #endif

    /// A fresh sign-in always re-reads the profile, so a suspension since the last session shows.
    private func finishSignIn(_ session: Session) async throws -> AuthSession {
        onboarded.remove(session.user.id)
        guard let made = try await makeSession(session) else {
            try? await ctx.client.auth.signOut(scope: .local)
            await publish(nil)
            loaded = true
            throw WaypointsError.suspended
        }
        await publish(made)
        loaded = true
        return made
    }

    func completeOnboarding() async throws {
        guard var session = current else { throw WaypointsError.notSignedIn }
        onboarded.insert(session.userID.raw)
        session.needsOnboarding = false
        await publish(session)
    }

    func signOut() async throws {
        await removeDeviceToken()
        do {
            try await ctx.client.auth.signOut()
        } catch {
            // Offline or an already-revoked token: drop the local session regardless.
            try? await ctx.client.auth.signOut(scope: .local)
        }
        await publish(nil)
    }

    func deleteAccount() async throws {
        let me = try ctx.me()
        // App Review 5.1.1(v): apps offering Sign in with Apple must revoke the user's
        // Apple token on deletion. Best effort and before the RPC: a fresh Apple
        // authorization code goes to the gateway, which exchanges it and revokes the
        // refresh token. Any failure is logged nowhere and ignored — deletion proceeds,
        // and Apple allows the same flow to be retried.
        await revokeAppleGrant()
        // Media first: storage objects have no cascade from auth.users, and the buckets are
        // public, so an orphaned file would stay readable with no owner able to delete it.
        // A failure here aborts the deletion; the user can retry.
        for bucket in MediaBucket.allCases where bucket != .catalog {
            let api = ctx.client.storage.from(bucket.rawValue)
            // `list` returns 100 names at a time; folders (id == nil) cannot be removed and
            // are skipped — uploads are flat "<uid>/<file>" paths.
            while true {
                let files = try await ctx.run { try await api.list(path: me.key) }
                guard !files.isEmpty else { break }
                let names = files.filter { $0.id != nil }.map { "\(me.key)/\($0.name)" }
                guard !names.isEmpty else { break }
                _ = try await ctx.run { try await api.remove(paths: names) }
                // A remove that quietly deleted nothing returns the same page on the
                // next list and would loop forever; abort so the user can retry.
                let again = try await ctx.run { try await api.list(path: me.key) }
                if again.map(\.name) == files.map(\.name) {
                    throw WaypointsError.invalid("storage cleanup")
                }
            }
        }
        try await Self.deleteAccountRow(ctx: ctx)
        DeviceTokenStore.clear()
        onboarded.remove(me.raw)
        try? await ctx.client.auth.signOut(scope: .local)
        await publish(nil)
    }

    /// `true` when the account has a Sign in with Apple identity. Email-code accounts
    /// have none, so they never see the extra Apple prompt at delete time.
    private static func signedInWithApple(_ user: User) -> Bool {
        if let identities = user.identities, !identities.isEmpty {
            return identities.contains { $0.provider == "apple" }
        }
        if let providers = user.appMetadata["providers"]?.arrayValue {
            return providers.contains { $0.stringValue == "apple" }
        }
        return user.appMetadata["provider"]?.stringValue == "apple"
    }

    /// Posts a fresh Apple authorization code to `POST /v1/apple/revoke`. Silent on
    /// every failure: revocation is best effort and must never block deletion.
    private func revokeAppleGrant() async {
        guard let user = ctx.client.auth.currentSession?.user, Self.signedInWithApple(user),
              let code = await AppleCredentialRequest().authorizationCode(),
              let token = try? await accessToken() else { return }
        var request = URLRequest(url: ctx.config.gatewayURL.appending(path: "v1/apple/revoke"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["authorization_code": code])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Best effort: drop this phone's APNs token while the session can still delete it, so a
    /// signed-out phone stops receiving pushes for the account.
    private func removeDeviceToken() async {
        guard let token = DeviceTokenStore.last else { return }
        if let me = try? ctx.me() {
            await Self.deleteDeviceTokenRow(ctx: ctx, user: me.key, token: token)
        }
        DeviceTokenStore.clear()
    }

    /// Nonisolated so the non-Sendable `PostgrestResponse` never crosses the actor boundary.
    private nonisolated static func deleteDeviceTokenRow(ctx: BackendContext, user: String, token: String) async {
        _ = try? await ctx.table("device_tokens").delete(returning: .minimal)
            .eq("user_id", value: user).eq("apns_token", value: token).execute()
    }

    private nonisolated static func accountFlags(ctx: BackendContext, id: UUID) async throws -> (acceptedTerms: Bool, suspended: Bool) {
        struct Flags: Decodable, Sendable { let acceptedTermsAt: Date?; let suspendedAt: Date? }
        struct TermsRow: Decodable, Sendable { let acceptedTermsAt: Date? }
        do {
            let row: Flags = try await ctx.table("profiles").select("accepted_terms_at,suspended_at")
                .eq("user_id", value: id).single().execute().value
            return (row.acceptedTermsAt.map { $0 >= Terms.effectiveAt } ?? false, row.suspendedAt != nil)
        } catch {
            // A database without the W7-1 migration has no `suspended_at` column yet.
            if let row: TermsRow? = try? await ctx.table("profiles").select("accepted_terms_at")
                .eq("user_id", value: id).single().execute().value {
                return (row.acceptedTermsAt.map { $0 >= Terms.effectiveAt } ?? false, false)
            }
            // Both reads failed: report the error, never "not suspended" by accident.
            throw error
        }
    }

    private nonisolated static func deleteAccountRow(ctx: BackendContext) async throws {
        do {
            _ = try await ctx.client.rpc("delete_account").execute()
        } catch {
            throw BackendContext.map(error)
        }
    }
}

/// The APNs token this phone last registered, so sign-out can remove it (NTF-5).
enum DeviceTokenStore {
    private static let key = "waypoints.apnsToken"

    static var last: String? { UserDefaults.standard.string(forKey: key) }

    static func remember(_ token: String) { UserDefaults.standard.set(token, forKey: key) }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// Runs one `ASAuthorizationAppleIDProvider` request at account-deletion time to obtain a
/// fresh authorization code for Apple token revocation (App Review 5.1.1(v)). Only the
/// code is needed — no scopes, no nonce. `nil` on cancel, failure, or no window; the
/// caller treats every outcome as best effort.
///
/// Main actor only: the controller presents in a window and its delegate is weak, so the
/// request object itself is what keeps the flow alive until it completes.
@MainActor
private final class AppleCredentialRequest: NSObject, ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<String?, Never>?

    func authorizationCode() async -> String? {
        guard Self.keyWindow != nil else { return nil }
        let apple = ASAuthorizationAppleIDProvider()
        let request = apple.createRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
            // performRequests() is not guaranteed to ever call a delegate method (a
            // failed presentation can end the flow silently); unstick the
            // continuation after a generous wait. finish() is idempotent.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                self?.finish(nil)
            }
        }
    }

    private static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.first?.windows.first { $0.windowScene?.activationState == .foregroundActive }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Called on the main thread by the controller.
        MainActor.assumeIsolated { Self.keyWindow ?? UIWindow() }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        let code = (authorization.credential as? ASAuthorizationAppleIDCredential)
            .flatMap(\.authorizationCode)
            .flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated { self.finish(code) }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: any Error) {
        MainActor.assumeIsolated { self.finish(nil) }
    }

    private func finish(_ code: String?) {
        continuation?.resume(returning: code)
        continuation = nil
        self.controller = nil
    }
}
