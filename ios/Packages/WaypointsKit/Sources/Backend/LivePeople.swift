import Core
import Foundation
import Supabase

/// `profiles`, own `privacy_settings` (read only), `device_tokens`.
struct LiveProfiles: ProfileRepository {
    let ctx: BackendContext
    let changes: Fanout<Profile>

    func myProfile() async throws -> Profile {
        try await profile(ctx.me())
    }

    func profile(_ id: UserID) async throws -> Profile {
        try await ctx.run {
            let row: ProfileRow = try await ctx.table("profiles").select().eq("user_id", value: id.key)
                .single().execute().value
            return row.model
        }
    }

    func profile(handle: String) async throws -> Profile? {
        try await ctx.run {
            let rows: [ProfileRow] = try await ctx.table("profiles").select()
                .eq("handle", value: handle.lowercased()).limit(1).execute().value
            return rows.first?.model
        }
    }

    func profiles(_ ids: [UserID]) async throws -> [Profile] {
        guard !ids.isEmpty else { return [] }
        return try await ctx.run {
            let rows: [ProfileRow] = try await ctx.table("profiles").select()
                .in("user_id", values: ids.map(\.key)).execute().value
            return rows.map(\.model)
        }
    }

    func profile(uid: RealtimeUID) async throws -> Profile? {
        try await ctx.run {
            let rows: [ProfileRow] = try await ctx.table("profiles").select()
                .eq("uid", value: String(uid)).limit(1).execute().value
            return rows.first?.model
        }
    }

    func search(_ query: String, limit: Int) async throws -> [Profile] {
        let q = filterSafe(query)
        guard !q.isEmpty else { return [] }
        return try await ctx.run {
            let rows: [ProfileRow] = try await ctx.table("profiles").select()
                .or("handle.ilike.*\(q)*,display_name.ilike.*\(q)*")
                .order("handle").limit(max(1, min(limit, 50))).execute().value
            return rows.map(\.model)
        }
    }

    func isHandleAvailable(_ handle: String) async throws -> Bool {
        let h = handle.lowercased()
        guard Profile.isValidHandle(h) else { return false }
        let me = try? ctx.me()
        return try await ctx.run {
            struct Row: Decodable { let userId: UUID }
            let rows: [Row] = try await ctx.table("profiles").select("user_id").eq("handle", value: h)
                .limit(1).execute().value
            return rows.allSatisfy { $0.userId == me?.raw }
        }
    }

    func updateMyProfile(_ update: ProfileUpdate) async throws -> Profile {
        let me = try ctx.me()
        if let handle = update.handle, !Profile.isValidHandle(handle) { throw WaypointsError.invalid("handle") }
        let profile = try await ctx.run {
            let row: ProfileRow = try await ctx.table("profiles").update(update)
                .eq("user_id", value: me.key).select().single().execute().value
            return row.model
        }
        await changes.send(profile)
        return profile
    }

    func acceptTerms() async throws {
        let me = try ctx.me()
        struct Body: Encodable { let acceptedTermsAt: Date }
        let profile = try await ctx.run {
            let row: ProfileRow = try await ctx.table("profiles").update(Body(acceptedTermsAt: .now))
                .eq("user_id", value: me.key).select().single().execute().value
            return row.model
        }
        await changes.send(profile)
    }

    func myPrivacySettings() async throws -> PrivacySettings {
        let me = try ctx.me()
        return try await ctx.run {
            let rows: [PrivacyRow] = try await ctx.table("privacy_settings").select()
                .eq("user_id", value: me.key).limit(1).execute().value
            return rows.first?.model ?? .defaults
        }
    }

    func registerDeviceToken(_ apnsToken: String, environment: APNsEnvironment) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let userId: UUID; let apnsToken: String; let environment: APNsEnvironment }
        try await ctx.run {
            // `device_tokens` has no update grant, so a repeat registration is ignored, not merged.
            _ = try await ctx.table("device_tokens")
                .upsert(Body(userId: me.raw, apnsToken: apnsToken, environment: environment),
                        onConflict: "user_id,apns_token", returning: .minimal, ignoreDuplicates: true)
                .execute()
        }
    }

    func removeDeviceToken(_ apnsToken: String) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("device_tokens").delete(returning: .minimal)
                .eq("user_id", value: me.key).eq("apns_token", value: apnsToken).execute()
        }
    }

    func myProfileChanges() async -> AsyncStream<Profile> {
        let stream = await changes.subscribe()
        if await changes.latest == nil, let profile = try? await myProfile() {
            await changes.send(profile)
        }
        return stream
    }
}

/// `friendships`. Only the addressee can accept (RLS enforces it).
struct LiveFriends: FriendRepository {
    let ctx: BackendContext
    let changes: Fanout<[Friend]>

    private func rows(_ me: UserID) async throws -> [FriendshipRow] {
        try await ctx.table("friendships").select()
            .or("requester_id.eq.\(me.key),addressee_id.eq.\(me.key)").execute().value
    }

    func friends() async throws -> [Friend] {
        let me = try ctx.me()
        return try await ctx.run {
            let accepted = try await rows(me).filter { $0.status == .accepted }.map(\.model)
            let ids = accepted.map { $0.other(than: me) }
            guard !ids.isEmpty else { return [] }
            let profiles: [ProfileRow] = try await ctx.table("profiles").select()
                .in("user_id", values: ids.map(\.key)).execute().value
            let carIDs = profiles.compactMap(\.primaryCarId)
            let cars: [CarRow] = carIDs.isEmpty ? [] : try await ctx.table("cars").select()
                .in("id", values: carIDs.map(\.uuidString)).execute().value
            let carsByID = Dictionary(cars.map { ($0.id, $0.car) }) { a, _ in a }
            let since = Dictionary(accepted.map { ($0.other(than: me).raw, $0.createdAt) }) { a, _ in a }
            return profiles.map { row in
                Friend(profile: row.model, primaryCar: row.primaryCarId.flatMap { carsByID[$0] },
                       since: since[row.userId] ?? row.createdAt)
            }
            .sorted { $0.profile.displayName.localizedCaseInsensitiveCompare($1.profile.displayName) == .orderedAscending }
        }
    }

    private func requests(incoming: Bool) async throws -> [FriendRequest] {
        let me = try ctx.me()
        return try await ctx.run {
            let column = incoming ? "addressee_id" : "requester_id"
            let pending: [FriendshipRow] = try await ctx.table("friendships").select()
                .eq(column, value: me.key).eq("status", value: "pending")
                .order("created_at", ascending: false).execute().value
            let ids = pending.map { incoming ? $0.requesterId : $0.addresseeId }
            guard !ids.isEmpty else { return [] }
            let profiles: [ProfileRow] = try await ctx.table("profiles").select()
                .in("user_id", values: ids.map(\.uuidString)).execute().value
            let byID = Dictionary(profiles.map { ($0.userId, $0.model) }) { a, _ in a }
            return pending.compactMap { row in
                byID[incoming ? row.requesterId : row.addresseeId].map { FriendRequest(profile: $0, sentAt: row.createdAt) }
            }
        }
    }

    func incomingRequests() async throws -> [FriendRequest] { try await requests(incoming: true) }
    func outgoingRequests() async throws -> [FriendRequest] { try await requests(incoming: false) }

    func friendship(with user: UserID) async throws -> Friendship? {
        let me = try ctx.me()
        return try await ctx.run {
            let rows: [FriendshipRow] = try await ctx.table("friendships").select()
                .or("and(requester_id.eq.\(me.key),addressee_id.eq.\(user.key)),"
                    + "and(requester_id.eq.\(user.key),addressee_id.eq.\(me.key))")
                .limit(1).execute().value
            return rows.first?.model
        }
    }

    func sendRequest(to user: UserID) async throws {
        let me = try ctx.me()
        guard me != user else { throw WaypointsError.invalid("user") }
        if let existing = try await friendship(with: user) {
            // They already asked us: sending back means accepting.
            if existing.status == .pending, existing.requesterID == user { try await acceptRequest(from: user) }
            return
        }
        struct Body: Encodable { let requesterId: UUID; let addresseeId: UUID }
        try await ctx.run {
            _ = try await ctx.table("friendships").insert(Body(requesterId: me.raw, addresseeId: user.raw),
                                                      returning: .minimal).execute()
        }
        await publish()
    }

    func acceptRequest(from user: UserID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let status: FriendshipStatus }
        let updated: [FriendshipRow] = try await ctx.run {
            try await ctx.table("friendships").update(Body(status: .accepted))
                .eq("requester_id", value: user.key).eq("addressee_id", value: me.key).select().execute().value
        }
        if updated.isEmpty { throw WaypointsError.notFound }
        await publish()
    }

    func remove(_ user: UserID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("friendships").delete(returning: .minimal)
                .or("and(requester_id.eq.\(me.key),addressee_id.eq.\(user.key)),"
                    + "and(requester_id.eq.\(user.key),addressee_id.eq.\(me.key))")
                .execute()
        }
        await publish()
    }

    /// `friendships` is not in the Realtime publication, so the stream re-emits after this
    /// device's own changes and on each new subscription.
    func friendChanges() async -> AsyncStream<[Friend]> {
        let stream = await changes.subscribe()
        await publish()
        return stream
    }

    private func publish() async {
        if let list = try? await friends() { await changes.send(list) }
    }
}
