import Core
import Foundation

/// Report and block flows, text filter, terms gate (plan section 10.10).
public enum SafetyKit {
    /// Live `SafetyService` against Supabase PostgREST. With no anon key it falls back to the
    /// preview store so a fresh clone runs.
    public static func makeLive(config: AppConfig, auth: any AuthService, profiles: any ProfileRepository) -> any SafetyService {
        guard !config.supabaseAnonKey.isEmpty else { return PreviewStore.shared }
        return LiveSafetyService(config: config, auth: auth, profiles: profiles)
    }
}

/// Words that block a post outright. Kept short and specific: the filter catches slurs and
/// threats, not ordinary swearing (car people swear).
enum WordList {
    static let blocked: Set<String> = [
        "nigger", "nigga", "faggot", "fag", "retard", "kike", "spic", "chink", "tranny", "wetback",
        "killyourself", "kys",
    ]

    static func check(_ text: String) -> TextCheck {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter }.map(String.init)
        if words.contains(where: blocked.contains) { return .blocked(reason: "language") }
        let squashed = folded.filter(\.isLetter)
        if squashed.contains("killyourself") { return .blocked(reason: "language") }
        return .ok
    }
}

actor LiveSafetyService: SafetyService {
    private let rest: URL
    private let anonKey: String
    private let auth: any AuthService
    private let profiles: any ProfileRepository
    private let session = URLSession(configuration: .ephemeral)
    private var blocked: Set<UserID> = []
    private var loaded = false
    private var continuations: [UUID: AsyncStream<Set<UserID>>.Continuation] = [:]

    init(config: AppConfig, auth: any AuthService, profiles: any ProfileRepository) {
        rest = config.supabaseURL.appending(path: "rest/v1")
        anonKey = config.supabaseAnonKey
        self.auth = auth
        self.profiles = profiles
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: rest.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal,resolution=ignore-duplicates", forHTTPHeaderField: "Prefer")
        req.httpBody = body
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw WaypointsError.offline
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 500
        switch code {
        case 200..<300: return data
        case 401: throw WaypointsError.notSignedIn
        case 403: throw WaypointsError.forbidden
        case 423: throw WaypointsError.suspended
        case 429: throw WaypointsError.rateLimited
        default: throw WaypointsError.server(String(decoding: data, as: UTF8.self))
        }
    }

    private func me() async throws -> UserID {
        guard let s = await auth.currentSession() else { throw WaypointsError.notSignedIn }
        return s.userID
    }

    private func load() async throws {
        guard !loaded else { return }
        let me = try await me()
        struct Row: Decodable { let blocked_id: UUID }
        let data = try await request("GET", "blocks", query: [
            .init(name: "select", value: "blocked_id"), .init(name: "blocker_id", value: "eq.\(me)"),
        ])
        blocked = Set(try JSONDecoder().decode([Row].self, from: data).map { UserID(raw: $0.blocked_id) })
        loaded = true
    }

    private func publish() {
        for c in continuations.values { c.yield(blocked) }
    }

    func report(_ target: ContentRef, reason: ContentReportReason, note: String?) async throws {
        let me = try await me()
        let body: [String: String?] = ["reporter_id": me.description, "target_kind": target.kind.rawValue,
                                       "target_id": target.id, "reason": reason.rawValue, "note": note]
        _ = try await request("POST", "content_reports", body: try JSONEncoder().encode(body))
    }

    func block(_ user: UserID) async throws {
        let me = try await me()
        try await load()
        let body = ["blocker_id": me.description, "blocked_id": user.description]
        _ = try await request("POST", "blocks", body: try JSONEncoder().encode(body))
        // Blocking ends any friendship either way.
        _ = try? await request("DELETE", "friendships", query: [.init(name: "or", value:
            "(and(requester_id.eq.\(me),addressee_id.eq.\(user)),and(requester_id.eq.\(user),addressee_id.eq.\(me)))")])
        blocked.insert(user)
        publish()
    }

    func unblock(_ user: UserID) async throws {
        let me = try await me()
        _ = try await request("DELETE", "blocks", query: [
            .init(name: "blocker_id", value: "eq.\(me)"), .init(name: "blocked_id", value: "eq.\(user)"),
        ])
        blocked.remove(user)
        publish()
    }

    func blockedUsers() async throws -> [Profile] {
        try await load()
        return try await profiles.profiles(Array(blocked)).sorted { $0.handle < $1.handle }
    }

    func blockedChanges() async -> AsyncStream<Set<UserID>> {
        try? await load()
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Set<UserID>.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(blocked)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }

    private func drop(_ id: UUID) { continuations[id] = nil }

    func check(_ text: String) async -> TextCheck { WordList.check(text) }

    func needsTermsAcceptance() async -> Bool {
        guard let profile = try? await profiles.myProfile() else { return true }
        return profile.acceptedTermsAt == nil
    }

    func acceptTerms() async throws { try await profiles.acceptTerms() }
}
