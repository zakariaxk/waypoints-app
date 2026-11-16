import Core
import Foundation

// Guides (section 4.26): `repair_guides` is read-only for clients except the
// KNW-8 helpful vote, which lives in `guide_votes` (mirrors post_likes).

struct GuideRow: Decodable, Sendable {
    let id: UUID
    let task: String
    let make: String
    let model: String?
    let variantId: Int64?
    let difficulty: Int
    let timeMinMinutes: Int
    let timeMaxMinutes: Int
    let tools: [String]
    let parts: [GuidePart]
    let steps: [String]
    let tradeoffs: String?
    let mistakes: String?
    let sources: [URL]
    let linkedModIds: [String]
    let votesCount: Int
    let createdAt: Date

    var guide: Guide {
        Guide(id: GuideID(raw: id), task: task, make: make, model: model, variantID: variantId,
              difficulty: difficulty, timeMinMinutes: timeMinMinutes, timeMaxMinutes: timeMaxMinutes,
              tools: tools, parts: parts, steps: steps, tradeoffs: tradeoffs, mistakes: mistakes,
              sources: sources, linkedModIDs: linkedModIds, votesCount: votesCount, createdAt: createdAt)
    }
}

struct LiveGuides: GuideRepository {
    let ctx: BackendContext

    private func voted(_ ids: [UUID]) async -> Set<UUID> {
        guard let me = try? ctx.me(), !ids.isEmpty else { return [] }
        struct Row: Decodable { let guideId: UUID }
        let rows: [Row] = (try? await ctx.table("guide_votes").select("guide_id").eq("user_id", value: me.key)
            .in("guide_id", values: ids.map { $0.uuidString.lowercased() }).execute().value) ?? []
        return Set(rows.map(\.guideId))
    }

    private func models(_ rows: [GuideRow]) async -> [Guide] {
        let votes = await voted(rows.map(\.id))
        return rows.map { row in
            var guide = row.guide
            guide.votedByMe = votes.contains(row.id)
            return guide
        }
    }

    func guidesForMake(_ make: String) async throws -> [Guide] {
        let rows: [GuideRow] = try await ctx.run {
            try await ctx.table("repair_guides").select()
                .eq("make", value: make).order("task").limit(200).execute().value
        }
        return await models(rows)
    }

    func guides(forModel make: String, model: String) async throws -> [Guide] {
        let rows: [GuideRow] = try await ctx.run {
            try await ctx.table("repair_guides").select()
                .eq("make", value: make).eq("model", value: model).order("task").limit(200).execute().value
        }
        return await models(rows)
    }

    func search(_ query: String) async throws -> [Guide] {
        let rows: [GuideRow] = try await ctx.run {
            try await ctx.table("repair_guides").select()
                .ilike("task", pattern: "%\(filterSafe(query))%").order("task").limit(100).execute().value
        }
        return await models(rows)
    }

    func guide(_ id: GuideID) async throws -> Guide {
        let row: GuideRow = try await ctx.run {
            try await ctx.table("repair_guides").select().eq("id", value: id.key).single().execute().value
        }
        return await models([row])[0]
    }

    func vote(_ id: GuideID) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let guideId: UUID; let userId: UUID }
        try await ctx.run {
            _ = try await ctx.table("guide_votes").upsert(Body(guideId: id.raw, userId: me.raw), onConflict: "guide_id,user_id",
                                                         returning: .minimal, ignoreDuplicates: true).execute()
        }
    }

    func unvote(_ id: GuideID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("guide_votes").delete(returning: .minimal).eq("guide_id", value: id.key).eq("user_id", value: me.key).execute()
        }
    }
}
