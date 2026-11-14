import Core
import Foundation
import Supabase

/// `notifications` over PostgREST (W7-2, NTF-6). Row-level security limits every query to the
/// signed-in user's rows; the `user_id` filter is there for the index.
struct LiveActivity: ActivityRepository {
    let ctx: BackendContext
    let unread: Fanout<Int>

    private struct NotificationRow: Decodable, Sendable {
        let id: UUID
        let kind: ActivityKind
        let actorId: UUID?
        let subjectUrl: String?
        let title: String
        let body: String?
        let readAt: Date?
        let createdAt: Date

        var model: ActivityItem {
            ActivityItem(id: ActivityID(raw: id), kind: kind, actorID: actorId.map(UserID.init(raw:)),
                         subjectURL: subjectUrl.flatMap(URL.init(string:)), title: title, body: body,
                         readAt: readAt, createdAt: createdAt)
        }
    }

    private struct IDRow: Decodable, Sendable { let id: UUID }

    func recent(limit: Int) async throws -> [ActivityItem] {
        let me = try ctx.me()
        let items = try await ctx.run {
            let rows: [NotificationRow] = try await ctx.table("notifications").select()
                .eq("user_id", value: me.key)
                .order("created_at", ascending: false)
                .limit(limit)
                .execute().value
            return rows.map(\.model)
        }
        await refreshUnread()
        return items
    }

    func markAllRead() async throws {
        let me = try ctx.me()
        struct Body: Encodable { let readAt: Date }
        try await ctx.run {
            _ = try await ctx.table("notifications").update(Body(readAt: .now), returning: .minimal)
                .eq("user_id", value: me.key)
                .is("read_at", value: nil)
                .execute()
        }
        await unread.send(0)
    }

    func unreadCount() async -> AsyncStream<Int> {
        let stream = await unread.subscribe()
        Task { await refreshUnread() }
        return stream
    }

    /// Counts up to 99 unread rows; the bell only shows whether there are any.
    private func refreshUnread() async {
        guard let me = try? ctx.me() else { return }
        let rows: [IDRow]? = try? await ctx.table("notifications").select("id")
            .eq("user_id", value: me.key)
            .is("read_at", value: nil)
            .limit(99)
            .execute().value
        if let rows { await unread.send(rows.count) }
    }
}
