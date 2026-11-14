import Core
import Foundation
import Supabase

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
                if let made = await makeSession(session) {
                    await publish(made)
                } else {
                    try? await ctx.client.auth.signOut(scope: .local)
                    await publish(nil)
                }
            } else if event == .initialSession {
                await publish(nil)
            }
        }
        loaded = true
    }

    private func publish(_ session: AuthSession?) async {
        guard session != current || !loaded else { return }
        current = session
        await fanout.send(session)
    }

    /// `nil` when the account is suspended.
    private func makeSession(_ session: Session) async -> AuthSession? {
        let id = session.user.id
        var needsOnboarding = !onboarded.contains(id)
        if needsOnboarding {
            let flags = await Self.accountFlags(ctx: ctx, id: id)
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
        loaded = true
        guard let made = await makeSession(session) else {
            try? await ctx.client.auth.signOut(scope: .local)
            await publish(nil)
            throw WaypointsError.suspended
        }
        await publish(made)
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
        // Best effort: remove the user's media first; database rows cascade from auth.users.
        for bucket in MediaBucket.allCases where bucket != .catalog {
            let api = ctx.client.storage.from(bucket.rawValue)
            if let files = try? await api.list(path: me.key), !files.isEmpty {
                _ = try? await api.remove(paths: files.map { "\(me.key)/\($0.name)" })
            }
        }
        try await Self.deleteAccountRow(ctx: ctx)
        DeviceTokenStore.clear()
        onboarded.remove(me.raw)
        try? await ctx.client.auth.signOut(scope: .local)
        await publish(nil)
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

    private nonisolated static func accountFlags(ctx: BackendContext, id: UUID) async -> (acceptedTerms: Bool, suspended: Bool) {
        struct Flags: Decodable, Sendable { let acceptedTermsAt: Date?; let suspendedAt: Date? }
        struct Terms: Decodable, Sendable { let acceptedTermsAt: Date? }
        if let row: Flags = try? await ctx.table("profiles").select("accepted_terms_at,suspended_at")
            .eq("user_id", value: id).single().execute().value {
            return (row.acceptedTermsAt != nil, row.suspendedAt != nil)
        }
        // A database without the W7-1 migration has no `suspended_at` column yet.
        let row: Terms? = try? await ctx.table("profiles").select("accepted_terms_at")
            .eq("user_id", value: id).single().execute().value
        return (row?.acceptedTermsAt != nil, false)
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
