import Core
import Foundation
import Supabase

// Teams, messages, posts, Showdown, market, progress (sections 5.4, 5.5).

// MARK: Teams

struct LiveTeams: TeamRepository {
    let ctx: BackendContext

    private func teams(ids: [UUID]) async throws -> [Team] {
        guard !ids.isEmpty else { return [] }
        return try await ctx.run {
            let rows: [TeamRow] = try await ctx.table("teams").select(teamColumns)
                .in("id", values: ids.map { $0.uuidString.lowercased() }).execute().value
            return rows.map(\.model)
        }
    }

    func myTeams() async throws -> [Team] {
        let me = try ctx.me()
        let ids: [UUID] = try await ctx.run {
            struct Row: Decodable { let teamId: UUID }
            let rows: [Row] = try await ctx.table("team_members").select("team_id").eq("user_id", value: me.key)
                .order("joined_at").execute().value
            return rows.map(\.teamId)
        }
        return try await teams(ids: ids).sorted { a, b in (ids.firstIndex(of: a.id.raw) ?? 0) < (ids.firstIndex(of: b.id.raw) ?? 0) }
    }

    func team(_ id: TeamID) async throws -> Team {
        try await ctx.run {
            let row: TeamRow = try await ctx.table("teams").select(teamColumns).eq("id", value: id.key).single().execute().value
            return row.model
        }
    }

    func publicTeams(matching query: String?) async throws -> [Team] {
        try await ctx.run {
            var q = ctx.table("teams").select(teamColumns).eq("is_public", value: true)
            if let query, !query.isEmpty { q = q.or("name.ilike.%\(filterSafe(query))%,tag.ilike.%\(filterSafe(query))%") }
            let rows: [TeamRow] = try await q.limit(50).execute().value
            return rows.map(\.model).sorted { $0.memberCount > $1.memberCount }
        }
    }

    func createTeam(_ draft: TeamDraft) async throws -> Team {
        let me = try ctx.me()
        struct Body: Encodable { let ownerId: UUID; let name: String; let tag: String; let about: String; let iconPath: String?; let isPublic: Bool }
        let id: UUID = try await ctx.run {
            let row: IDRow = try await ctx.table("teams")
                .insert(Body(ownerId: me.raw, name: draft.name, tag: draft.tag.uppercased(), about: draft.about,
                             iconPath: draft.iconPath, isPublic: draft.isPublic))
                .select("id").single().execute().value
            return row.id
        }
        return try await team(TeamID(raw: id))
    }

    func updateTeam(_ team: Team) async throws -> Team {
        struct Body: Encodable { let name: String; let tag: String; let about: String; let iconPath: String?; let isPublic: Bool }
        try await ctx.run {
            _ = try await ctx.table("teams")
                .update(Body(name: team.name, tag: team.tag, about: team.about, iconPath: team.iconPath, isPublic: team.isPublic),
                        returning: .minimal)
                .eq("id", value: team.id.key).execute()
        }
        return try await self.team(team.id)
    }

    func deleteTeam(_ id: TeamID) async throws {
        try await ctx.run { _ = try await ctx.table("teams").delete(returning: .minimal).eq("id", value: id.key).execute() }
    }

    func join(code: String) async throws -> Team {
        struct Params: Encodable { let code: String }
        let id: UUID = try await ctx.run {
            try await ctx.client.rpc("join_team", params: Params(code: code)).execute().value
        }
        return try await team(TeamID(raw: id))
    }

    func joinPublic(_ id: TeamID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let teamId: UUID; let userId: UUID }
        try await ctx.run {
            _ = try await ctx.table("team_members").insert(Body(teamId: id.raw, userId: me.raw), returning: .minimal).execute()
        }
    }

    func leave(_ id: TeamID) async throws {
        let me = try ctx.me()
        try await kick(me, from: id)
    }

    func members(of team: TeamID) async throws -> [TeamMember] {
        try await ctx.run {
            let rows: [TeamMemberRow] = try await ctx.table("team_members").select().eq("team_id", value: team.key)
                .order("joined_at").execute().value
            return rows.map(\.model)
        }
    }

    func roles(of team: TeamID) async throws -> [TeamRole] {
        try await ctx.run {
            let rows: [TeamRoleRow] = try await ctx.table("team_roles").select().eq("team_id", value: team.key)
                .order("rank", ascending: false).execute().value
            return rows.map(\.model)
        }
    }

    func saveRole(_ role: TeamRole) async throws -> TeamRole {
        struct Body: Encodable { let id: UUID; let teamId: UUID; let name: String; let colorHex: String?; let rank: Int; let permissions: Int }
        return try await ctx.run {
            let row: TeamRoleRow = try await ctx.table("team_roles")
                .upsert(Body(id: role.id.raw, teamId: role.teamID.raw, name: role.name, colorHex: role.colorHex, rank: role.rank,
                             permissions: role.permissions.rawValue))
                .select().single().execute().value
            return row.model
        }
    }

    func deleteRole(_ id: TeamRoleID) async throws {
        try await ctx.run { _ = try await ctx.table("team_roles").delete(returning: .minimal).eq("id", value: id.key).execute() }
    }

    func assign(_ role: TeamRoleID?, to user: UserID, in team: TeamID) async throws {
        struct Body: Encodable { let roleId: Nullable<UUID> }
        try await ctx.run {
            _ = try await ctx.table("team_members").update(Body(roleId: .init(role?.raw)), returning: .minimal)
                .eq("team_id", value: team.key).eq("user_id", value: user.key).execute()
        }
    }

    func kick(_ user: UserID, from team: TeamID) async throws {
        try await ctx.run {
            _ = try await ctx.table("team_members").delete(returning: .minimal)
                .eq("team_id", value: team.key).eq("user_id", value: user.key).execute()
        }
    }

    func myPermissions(in team: TeamID) async throws -> TeamPermissions {
        struct Params: Encodable { let team: UUID }
        let bits: Int = try await ctx.run {
            try await ctx.client.rpc("team_permissions", params: Params(team: team.raw)).execute().value
        }
        return TeamPermissions(rawValue: bits)
    }

    func channels(of team: TeamID) async throws -> [Channel] {
        try await ctx.run {
            let rows: [ChannelRow] = try await ctx.table("channels").select().eq("team_id", value: team.key).order("sort")
                .execute().value
            return rows.map(\.model)
        }
    }

    func channel(_ id: ChannelID) async throws -> Channel {
        try await ctx.run {
            let row: ChannelRow = try await ctx.table("channels").select().eq("id", value: id.key).single().execute().value
            return row.model
        }
    }

    func saveChannel(_ channel: Channel) async throws -> Channel {
        struct Body: Encodable { let id: UUID; let teamId: UUID; let name: String; let kind: ChannelKind; let sort: Int }
        return try await ctx.run {
            let row: ChannelRow = try await ctx.table("channels")
                .upsert(Body(id: channel.id.raw, teamId: channel.teamID.raw, name: channel.name, kind: channel.kind, sort: channel.sort))
                .select().single().execute().value
            return row.model
        }
    }

    func deleteChannel(_ id: ChannelID) async throws {
        try await ctx.run { _ = try await ctx.table("channels").delete(returning: .minimal).eq("id", value: id.key).execute() }
    }
}

// MARK: Messages

struct LiveMessages: MessageRepository {
    let ctx: BackendContext
    let unread: Fanout<Int>

    private func column(_ t: MessageTarget) -> (String, String) {
        switch t {
        case let .channel(id): ("channel_id", id.key)
        case let .thread(id): ("thread_id", id.key)
        }
    }

    func messages(in target: MessageTarget, before: MessageID?, limit: Int) async throws -> [Core.Message] {
        let (col, value) = column(target)
        return try await ctx.run {
            var q = ctx.table("messages").select().eq(col, value: value)
            if let before { q = q.lt("id", value: String(before.raw)) }
            let rows: [MessageRow] = try await q.order("id", ascending: false).limit(limit).execute().value
            return rows.compactMap(\.model)
        }
    }

    func send(_ body: String, attachmentPath: String?, to target: MessageTarget) async throws -> Core.Message {
        let me = try ctx.me()
        struct Body: Encodable { let channelId: UUID?; let threadId: UUID?; let authorId: UUID; let body: String; let attachmentPath: String? }
        let b: Body = switch target {
        case let .channel(id): Body(channelId: id.raw, threadId: nil, authorId: me.raw, body: body, attachmentPath: attachmentPath)
        case let .thread(id): Body(channelId: nil, threadId: id.raw, authorId: me.raw, body: body, attachmentPath: attachmentPath)
        }
        let row: MessageRow = try await ctx.run {
            try await ctx.table("messages").insert(b).select().single().execute().value
        }
        guard let m = row.model else { throw WaypointsError.server("message") }
        return m
    }

    func delete(_ id: MessageID) async throws {
        struct Body: Encodable { let deletedAt: Date }
        try await ctx.run {
            _ = try await ctx.table("messages").update(Body(deletedAt: .now), returning: .minimal).eq("id", value: String(id.raw)).execute()
        }
    }

    func live(_ target: MessageTarget) async -> AsyncStream<Core.Message> {
        let (col, value) = column(target)
        let channel = ctx.client.channel("messages:\(value)")
        let changes = channel.postgresChange(AnyAction.self, schema: "public", table: "messages", filter: "\(col)=eq.\(value)")
        let decoder = Coders.decoder()
        return AsyncStream { continuation in
            let task = Task {
                try? await channel.subscribeWithError()
                for await change in changes {
                    let row: MessageRow? = switch change {
                    case let .insert(a): try? a.decodeRecord(as: MessageRow.self, decoder: decoder)
                    case let .update(a): try? a.decodeRecord(as: MessageRow.self, decoder: decoder)
                    case .delete: nil
                    }
                    if let m = row?.model { continuation.yield(m) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await channel.unsubscribe() }
            }
        }
    }

    func threads() async throws -> [MessageThread] {
        let me = try ctx.me()
        let rows: [ThreadRow] = try await ctx.run {
            try await ctx.table("threads").select().or("a_id.eq.\(me.key),b_id.eq.\(me.key)").order("created_at", ascending: false)
                .limit(100).execute().value
        }
        let markers = try await readMarkers()
        var out: [MessageThread] = []
        for r in rows {
            let last = try? await messages(in: .thread(ThreadID(raw: r.id)), before: nil, limit: 1).first
            let read = markers[.thread(ThreadID(raw: r.id))] ?? 0
            let unread = (last.map { $0.id.raw > read && $0.authorID != me } ?? false) ? 1 : 0
            out.append(r.model(lastMessage: last, unread: unread))
        }
        return out.sorted { ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt) }
    }

    private func readMarkers() async throws -> [MessageTarget: Int64] {
        let me = try ctx.me()
        let rows: [ReadMarkerRow] = try await ctx.run {
            try await ctx.table("read_markers").select("channel_id,thread_id,last_read_message_id").eq("user_id", value: me.key)
                .execute().value
        }
        var out: [MessageTarget: Int64] = [:]
        for r in rows {
            if let c = r.channelId { out[.channel(ChannelID(raw: c))] = r.lastReadMessageId }
            if let t = r.threadId { out[.thread(ThreadID(raw: t))] = r.lastReadMessageId }
        }
        return out
    }

    func openThread(with user: UserID, listing: ListingID?) async throws -> MessageThread {
        let me = try ctx.me()
        let kind: ThreadKind = listing == nil ? .dm : .listing
        let existing: [ThreadRow] = try await ctx.run {
            var q = ctx.table("threads").select().eq("kind", value: kind.rawValue)
                .or("and(a_id.eq.\(me.key),b_id.eq.\(user.key)),and(a_id.eq.\(user.key),b_id.eq.\(me.key))")
            q = listing.map { q.eq("listing_id", value: $0.key) } ?? q.is("listing_id", value: nil)
            return try await q.limit(1).execute().value
        }
        if let t = existing.first { return t.model() }
        struct Body: Encodable { let kind: ThreadKind; let listingId: UUID?; let aId: UUID; let bId: UUID }
        let row: ThreadRow = try await ctx.run {
            try await ctx.table("threads").insert(Body(kind: kind, listingId: listing?.raw, aId: me.raw, bId: user.raw))
                .select().single().execute().value
        }
        return row.model()
    }

    func markRead(_ target: MessageTarget, upTo id: MessageID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let userId: UUID; let channelId: UUID?; let threadId: UUID?; let lastReadMessageId: Int64 }
        let b: Body = switch target {
        case let .channel(c): Body(userId: me.raw, channelId: c.raw, threadId: nil, lastReadMessageId: id.raw)
        case let .thread(t): Body(userId: me.raw, channelId: nil, threadId: t.raw, lastReadMessageId: id.raw)
        }
        try await ctx.run {
            _ = try await ctx.table("read_markers").upsert(b, onConflict: "user_id,channel_id,thread_id", returning: .minimal).execute()
        }
        await unread.send(await countUnread())
    }

    private func countUnread() async -> Int {
        ((try? await threads()) ?? []).reduce(0) { $0 + $1.unreadCount }
    }

    func unreadCount() async -> AsyncStream<Int> {
        let stream = await unread.subscribe(initial: 0)
        let fan = unread
        let count = await countUnread()
        await fan.send(count)
        return stream
    }
}

// MARK: Posts

struct LivePosts: PostRepository {
    let ctx: BackendContext

    private func liked(_ ids: [UUID]) async -> Set<UUID> {
        guard let me = try? ctx.me(), !ids.isEmpty else { return [] }
        struct Row: Decodable { let postId: UUID }
        let rows: [Row] = (try? await ctx.table("post_likes").select("post_id").eq("user_id", value: me.key)
            .in("post_id", values: ids.map { $0.uuidString.lowercased() }).execute().value) ?? []
        return Set(rows.map(\.postId))
    }

    private func models(_ rows: [PostRow]) async -> [Post] {
        let likes = await liked(rows.map(\.id))
        return rows.map { $0.model(liked: likes.contains($0.id)) }
    }

    func feed(after cursor: PageCursor?, limit: Int) async throws -> Page<Post> {
        let rows: [PostRow] = try await ctx.run {
            var q = ctx.table("posts").select()
            if let cursor { q = q.lt("created_at", value: cursor.raw) }
            return try await q.order("created_at", ascending: false).limit(limit).execute().value
        }
        let next = rows.count == limit ? rows.last.map { PageCursor(raw: PostgresDate.timestamp($0.createdAt)) } : nil
        return Page(items: await models(rows), next: next)
    }

    func posts(by author: UserID) async throws -> [Post] {
        let rows: [PostRow] = try await ctx.run {
            try await ctx.table("posts").select().eq("author_id", value: author.key).order("created_at", ascending: false)
                .limit(60).execute().value
        }
        return await models(rows)
    }

    func post(_ id: PostID) async throws -> Post {
        let row: PostRow = try await ctx.run {
            try await ctx.table("posts").select().eq("id", value: id.key).single().execute().value
        }
        return await models([row])[0]
    }

    func createPost(_ post: NewPost) async throws -> Post {
        let me = try ctx.me()
        struct Body: Encodable { let authorId: UUID; let carId: UUID?; let videoPath: String; let posterPath: String; let caption: String; let durationMs: Int }
        let row: PostRow = try await ctx.run {
            try await ctx.table("posts").insert(Body(authorId: me.raw, carId: post.carID?.raw, videoPath: post.videoPath,
                                                     posterPath: post.posterPath, caption: post.caption, durationMs: post.durationMs))
                .select().single().execute().value
        }
        return row.model(liked: false)
    }

    func deletePost(_ id: PostID) async throws {
        try await ctx.run { _ = try await ctx.table("posts").delete(returning: .minimal).eq("id", value: id.key).execute() }
    }

    func like(_ id: PostID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let postId: UUID; let userId: UUID }
        try await ctx.run {
            _ = try await ctx.table("post_likes").upsert(Body(postId: id.raw, userId: me.raw), onConflict: "post_id,user_id",
                                                        returning: .minimal, ignoreDuplicates: true).execute()
        }
    }

    func unlike(_ id: PostID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("post_likes").delete(returning: .minimal).eq("post_id", value: id.key).eq("user_id", value: me.key).execute()
        }
    }

    func comments(on post: PostID) async throws -> [PostComment] {
        try await ctx.run {
            let rows: [CommentRow] = try await ctx.table("post_comments").select().eq("post_id", value: post.key)
                .order("created_at").limit(200).execute().value
            return rows.map(\.model)
        }
    }

    func addComment(_ body: String, to post: PostID) async throws -> PostComment {
        let me = try ctx.me()
        struct Body: Encodable { let postId: UUID; let authorId: UUID; let body: String }
        return try await ctx.run {
            let row: CommentRow = try await ctx.table("post_comments").insert(Body(postId: post.raw, authorId: me.raw, body: body))
                .select().single().execute().value
            return row.model
        }
    }

    func deleteComment(_ id: CommentID) async throws {
        try await ctx.run { _ = try await ctx.table("post_comments").delete(returning: .minimal).eq("id", value: id.key).execute() }
    }

    func follow(_ user: UserID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let followerId: UUID; let followeeId: UUID }
        try await ctx.run {
            _ = try await ctx.table("follows").upsert(Body(followerId: me.raw, followeeId: user.raw), onConflict: "follower_id,followee_id",
                                                     returning: .minimal, ignoreDuplicates: true).execute()
        }
    }

    func unfollow(_ user: UserID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("follows").delete(returning: .minimal).eq("follower_id", value: me.key)
                .eq("followee_id", value: user.key).execute()
        }
    }

    func isFollowing(_ user: UserID) async throws -> Bool {
        let me = try ctx.me()
        struct Row: Decodable { let followeeId: UUID }
        let rows: [Row] = try await ctx.run {
            try await ctx.table("follows").select("followee_id").eq("follower_id", value: me.key).eq("followee_id", value: user.key)
                .limit(1).execute().value
        }
        return !rows.isEmpty
    }
}

// MARK: Showdown

struct LiveShowdown: ShowdownRepository {
    let ctx: BackendContext
    let garage: any GarageRepository
    let profiles: any ProfileRepository

    func entry(for car: CarID) async throws -> ShowdownEntry? {
        try await ctx.run {
            let rows: [ShowdownRow] = try await ctx.table("showdown_entries").select().eq("car_id", value: car.key).limit(1).execute().value
            return rows.first?.model
        }
    }

    func enter(_ car: CarID, class showdownClass: ShowdownClass) async throws -> ShowdownEntry {
        struct Body: Encodable { let carId: UUID; let `class`: ShowdownClass }
        return try await ctx.run {
            let row: ShowdownRow = try await ctx.table("showdown_entries").insert(Body(carId: car.raw, class: showdownClass))
                .select().single().execute().value
            return row.model
        }
    }

    func withdraw(_ car: CarID) async throws {
        try await ctx.run { _ = try await ctx.table("showdown_entries").delete(returning: .minimal).eq("car_id", value: car.key).execute() }
    }

    private func contender(_ e: ShowdownEntry) async throws -> ShowdownContender {
        let car = try await garage.car(e.carID)
        return ShowdownContender(car: car, owner: try await profiles.profile(car.ownerID),
                                 photos: try await garage.photos(of: e.carID), entry: e)
    }

    func nextPair(in showdownClass: ShowdownClass) async throws -> ShowdownPair? {
        let me = try ctx.me()
        let entries: [ShowdownEntry] = try await ctx.run {
            let rows: [ShowdownRow] = try await ctx.table("showdown_entries").select().eq("class", value: showdownClass.rawValue)
                .limit(300).execute().value
            return rows.map(\.model)
        }
        let mine = Set(try await garage.cars(of: me).map(\.id))
        struct Vote: Decodable { let winnerCarId: UUID; let loserCarId: UUID }
        let votes: [Vote] = try await ctx.run {
            try await ctx.table("showdown_votes").select("winner_car_id,loser_car_id").eq("voter_id", value: me.key).execute().value
        }
        let judged = Set(votes.map { Set([$0.winnerCarId, $0.loserCarId]) })
        let pool = entries.filter { !mine.contains($0.carID) }.shuffled()
        for (i, a) in pool.enumerated() {
            for b in pool[(i + 1)...] where abs(a.rating - b.rating) <= 150 && !judged.contains(Set([a.carID.raw, b.carID.raw])) {
                return ShowdownPair(left: try await contender(a), right: try await contender(b))
            }
        }
        return nil
    }

    func vote(winner: CarID, loser: CarID) async throws {
        struct Params: Encodable { let winner: UUID; let loser: UUID }
        try await ctx.run {
            _ = try await ctx.client.rpc("cast_showdown_vote", params: Params(winner: winner.raw, loser: loser.raw)).execute()
        }
    }

    func rankings(in showdownClass: ShowdownClass, period: RankingPeriod, limit: Int) async throws -> [ShowdownContender] {
        let entries: [ShowdownEntry] = try await ctx.run {
            let rows: [ShowdownRow] = try await ctx.table("showdown_entries").select().eq("class", value: showdownClass.rawValue)
                .order("rating", ascending: false).limit(period == .allTime ? limit : 200).execute().value
            return rows.map(\.model)
        }
        var ordered = entries
        if period == .week {
            struct Vote: Decodable { let winnerCarId: UUID }
            let votes: [Vote] = try await ctx.run {
                try await ctx.table("showdown_votes").select("winner_car_id")
                    .gt("created_at", value: Date.now.addingTimeInterval(-7 * 86400)).limit(5000).execute().value
            }
            let wins = Dictionary(grouping: votes, by: \.winnerCarId).mapValues(\.count)
            ordered = entries.filter { wins[$0.carID.raw] != nil }
                .sorted { (wins[$0.carID.raw] ?? 0, $0.rating) > (wins[$1.carID.raw] ?? 0, $1.rating) }
        }
        var out: [ShowdownContender] = []
        for e in ordered.prefix(limit) { if let c = try? await contender(e) { out.append(c) } }
        return out
    }
}

// MARK: Market

struct LiveMarket: MarketRepository {
    let ctx: BackendContext

    private func saved() async -> Set<UUID> {
        guard let me = try? ctx.me() else { return [] }
        struct Row: Decodable { let listingId: UUID }
        let rows: [Row] = (try? await ctx.table("listing_saves").select("listing_id").eq("user_id", value: me.key).execute().value) ?? []
        return Set(rows.map(\.listingId))
    }

    func listings(_ filter: ListingFilter, after cursor: PageCursor?, limit: Int) async throws -> Page<Listing> {
        let rows: [ListingRow] = try await ctx.run {
            var q = ctx.table("listings").select(listingColumns).eq("status", value: ListingStatus.active.rawValue)
            if let k = filter.kind { q = q.eq("kind", value: k.rawValue) }
            if let c = filter.category { q = q.eq("category", value: c.rawValue) }
            if let text = filter.query, !text.isEmpty { q = q.ilike("title", pattern: "%\(filterSafe(text))%") }
            if let f = filter.fits {
                q = q.eq("fits_make", value: f.make)
                if let m = f.model { q = q.eq("fits_model", value: m) }
                if let y = f.yearFrom { q = q.or("fits_year_to.is.null,fits_year_to.gte.\(y)") }
                if let y = f.yearTo { q = q.or("fits_year_from.is.null,fits_year_from.lte.\(y)") }
            }
            if let cursor { q = q.lt("created_at", value: cursor.raw) }
            return try await q.order("created_at", ascending: false).limit(limit).execute().value
        }
        let s = await saved()
        let next = rows.count == limit ? rows.last.map { PageCursor(raw: PostgresDate.timestamp($0.createdAt)) } : nil
        return Page(items: rows.map { $0.model(saved: s.contains($0.id)) }, next: next)
    }

    func listing(_ id: ListingID) async throws -> Listing {
        let row: ListingRow = try await ctx.run {
            try await ctx.table("listings").select(listingColumns).eq("id", value: id.key).single().execute().value
        }
        return row.model(saved: await saved().contains(row.id))
    }

    func listings(by seller: UserID) async throws -> [Listing] {
        let rows: [ListingRow] = try await ctx.run {
            try await ctx.table("listings").select(listingColumns).eq("seller_id", value: seller.key).neq("status", value: "removed")
                .order("created_at", ascending: false).execute().value
        }
        let s = await saved()
        return rows.map { $0.model(saved: s.contains($0.id)) }
    }

    func createListing(_ draft: ListingDraft) async throws -> Listing {
        let me = try ctx.me()
        let write = ListingWrite(kind: draft.kind, title: draft.title, priceCents: draft.priceCents, condition: draft.condition,
                                 description: draft.description, fits: draft.fits, carID: draft.carID, region: draft.region,
                                 seller: me, status: .active, category: draft.category)
        let id: UUID = try await ctx.run {
            let row: IDRow = try await ctx.table("listings").insert(write).select("id").single().execute().value
            return row.id
        }
        struct Photo: Encodable { let listingId: UUID; let path: String; let sort: Int }
        if !draft.photoPaths.isEmpty {
            let photos = draft.photoPaths.enumerated().map { Photo(listingId: id, path: $1, sort: $0) }
            try await ctx.run { _ = try await ctx.table("listing_photos").insert(photos, returning: .minimal).execute() }
        }
        return try await listing(ListingID(raw: id))
    }

    func updateListing(_ l: Listing) async throws -> Listing {
        let write = ListingWrite(kind: l.kind, title: l.title, priceCents: l.priceCents, condition: l.condition,
                                 description: l.description, fits: l.fits, carID: l.carID, region: l.region, seller: nil, status: l.status,
                                 category: l.category)
        try await ctx.run {
            _ = try await ctx.table("listings").update(write, returning: .minimal).eq("id", value: l.id.key).execute()
        }
        return try await listing(l.id)
    }

    func setStatus(_ status: ListingStatus, for id: ListingID) async throws {
        struct Body: Encodable { let status: ListingStatus }
        try await ctx.run {
            _ = try await ctx.table("listings").update(Body(status: status), returning: .minimal).eq("id", value: id.key).execute()
        }
    }

    func save(_ id: ListingID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let listingId: UUID; let userId: UUID }
        try await ctx.run {
            _ = try await ctx.table("listing_saves").upsert(Body(listingId: id.raw, userId: me.raw), onConflict: "listing_id,user_id",
                                                           returning: .minimal, ignoreDuplicates: true).execute()
        }
    }

    func unsave(_ id: ListingID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("listing_saves").delete(returning: .minimal).eq("listing_id", value: id.key)
                .eq("user_id", value: me.key).execute()
        }
    }

    func savedListings() async throws -> [Listing] {
        let ids = await saved()
        guard !ids.isEmpty else { return [] }
        let rows: [ListingRow] = try await ctx.run {
            try await ctx.table("listings").select(listingColumns).in("id", values: ids.map { $0.uuidString.lowercased() }).execute().value
        }
        return rows.map { $0.model(saved: true) }
    }
}

// MARK: Progress

struct LiveProgress: ProgressRepository {
    let ctx: BackendContext

    /// Targets for every key (plan 9.8 and W5-5).
    static let targets: [String: Int] = [
        "first_meet": 1, "host_3": 3, "reports_10": 10, "reports_50": 50, "spots_25": 25, "spots_100": 100, "roads_5": 5,
        "build_10": 10, "showdown_top10": 1, "convoy_lead": 1, "strip_12s": 1, "strip_10s": 1, "teams_join": 1, "meets_5": 5,
        "friends_5": 5, "convoy_3": 3, "listing_1": 1, "showdown_50": 50, "build_25": 25, "venue_5": 5, "reports_1": 1,
        "meets_1": 1, "convoy_1": 1, "spots_5": 5, "strip_1": 1, "roads_1": 1, "posts_5": 5,
    ]

    func achievements(of user: UserID) async throws -> [Achievement] {
        try await ctx.run {
            let rows: [AchievementRow] = try await ctx.table("achievements").select().eq("user_id", value: user.key).execute().value
            return rows.map(\.model)
        }
    }

    private func count(_ table: String, _ column: String, _ me: UserID) async -> Int {
        let rows: [IDLess] = (try? await ctx.table(table).select(column).eq(column, value: me.key).limit(1000).execute().value) ?? []
        return rows.count
    }

    private struct IDLess: Decodable {}

    func myProgress() async throws -> [AchievementProgress] {
        let me = try ctx.me()
        let earned = Dictionary(uniqueKeysWithValues: try await achievements(of: me).map { ($0.key, $0.earnedAt) })
        struct Conf: Decodable { let confirmations: Int }
        let reports: [Conf] = (try? await ctx.table("reports").select("confirmations").eq("author_id", value: me.key).execute().value) ?? []
        let confirmed = reports.filter { $0.confirmations > 1 }.count
        struct Spot: Decodable { let catalogModelId: Int64 }
        let spots: [Spot] = (try? await ctx.table("spots").select("catalog_model_id").eq("spotter_id", value: me.key).execute().value) ?? []
        let roads = await count("road_ratings", "user_id", me)
        let posts = await count("posts", "author_id", me)
        let listings = await count("listings", "seller_id", me)
        let venue = await count("venue_notes", "author_id", me)
        let teams = await count("team_members", "user_id", me)
        struct Race: Decodable { let etMs: Int }
        let races: [Race] = (try? await ctx.table("race_results").select("et_ms").eq("user_id", value: me.key).execute().value) ?? []
        let best = races.map(\.etMs).min() ?? Int.max
        let current: [String: Int] = [
            "reports_1": confirmed, "reports_10": confirmed, "reports_50": confirmed,
            "spots_5": Set(spots.map(\.catalogModelId)).count, "spots_25": Set(spots.map(\.catalogModelId)).count,
            "spots_100": Set(spots.map(\.catalogModelId)).count, "roads_1": roads, "roads_5": roads, "posts_5": posts,
            "listing_1": listings, "venue_5": venue, "teams_join": teams, "strip_1": races.count,
            "strip_12s": best < 12000 ? 1 : 0, "strip_10s": best < 10000 ? 1 : 0,
        ]
        return Self.targets.map { key, target in
            let c = min(current[key] ?? (earned[key] != nil ? target : 0), target)
            return AchievementProgress(key: key, current: c, target: target, earnedAt: earned[key] ?? (c >= target && current[key] != nil ? .now : nil))
        }
    }

    func saveRaceResult(_ r: RaceResult) async throws -> RaceResult {
        let me = try ctx.me()
        struct Body: Encodable {
            let userId: UUID; let carId: UUID; let mods: [String]; let reactionMs: Int; let etMs: Int; let trapMphX10: Int
            let sixtyFtMs: Int; let inputLog: String
        }
        return try await ctx.run {
            let row: RaceResultRow = try await ctx.table("race_results")
                .insert(Body(userId: me.raw, carId: r.carID.raw, mods: r.mods, reactionMs: r.reactionMs, etMs: r.etMs,
                             trapMphX10: r.trapMphX10, sixtyFtMs: r.sixtyFtMs, inputLog: Bytea.encode(r.inputLog)))
                .select().single().execute().value
            return row.model
        }
    }

    func raceResults(for car: CarID) async throws -> [RaceResult] {
        try await ctx.run {
            let rows: [RaceResultRow] = try await ctx.table("race_results").select().eq("car_id", value: car.key)
                .order("created_at", ascending: false).limit(50).execute().value
            return rows.map(\.model)
        }
    }

    func raceResults(by user: UserID, limit: Int) async throws -> [RaceResult] {
        try await ctx.run {
            let rows: [RaceResultRow] = try await ctx.table("race_results").select().eq("user_id", value: user.key)
                .order("et_ms").limit(limit).execute().value
            return rows.map(\.model)
        }
    }

    func bestRaceResults(limit: Int) async throws -> [RaceResult] {
        let me = try ctx.me()
        return try await ctx.run {
            let rows: [RaceResultRow] = try await ctx.table("race_results").select().eq("user_id", value: me.key)
                .order("et_ms").limit(limit).execute().value
            return rows.map(\.model)
        }
    }
}
