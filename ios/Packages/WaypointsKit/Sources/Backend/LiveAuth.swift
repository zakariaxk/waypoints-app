import Core
import Foundation
import Supabase

/// Supabase Auth: Sign in with Apple (ID token + nonce), email one-time code, automatic
/// refresh (the SDK refreshes before expiry and `accessToken()` refreshes on demand),
/// sign-out, and account deletion through the `delete_account` RPC.
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
                await publish(await makeSession(session))
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

    private func makeSession(_ session: Session) async -> AuthSession {
        let id = session.user.id
        var needsOnboarding = !onboarded.contains(id)
        if needsOnboarding {
            if await Self.acceptedTerms(ctx: ctx, id: id) {
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
        let made = await makeSession(session)
        loaded = true
        await publish(made)
        return made
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
        let made = await makeSession(session)
        loaded = true
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
        onboarded.remove(me.raw)
        try? await ctx.client.auth.signOut(scope: .local)
        await publish(nil)
    }

    private nonisolated static func acceptedTerms(ctx: BackendContext, id: UUID) async -> Bool {
        struct Terms: Decodable, Sendable { let acceptedTermsAt: Date? }
        let row: Terms? = try? await ctx.table("profiles").select("accepted_terms_at")
            .eq("user_id", value: id).single().execute().value
        return row?.acceptedTermsAt != nil
    }

    private nonisolated static func deleteAccountRow(ctx: BackendContext) async throws {
        do {
            _ = try await ctx.client.rpc("delete_account").execute()
        } catch {
            throw BackendContext.map(error)
        }
    }
}
