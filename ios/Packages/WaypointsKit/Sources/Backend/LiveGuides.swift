import Core
import Foundation

// Guides (section 4.26): `repair_guides` is read-only for clients.

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
    let createdAt: Date

    var guide: Guide {
        Guide(id: GuideID(raw: id), task: task, make: make, model: model, variantID: variantId,
              difficulty: difficulty, timeMinMinutes: timeMinMinutes, timeMaxMinutes: timeMaxMinutes,
              tools: tools, parts: parts, steps: steps, tradeoffs: tradeoffs, mistakes: mistakes,
              sources: sources, linkedModIDs: linkedModIds, createdAt: createdAt)
    }
}

struct LiveGuides: GuideRepository {
    let ctx: BackendContext

    func guidesForMake(_ make: String) async throws -> [Guide] {
        try await ctx.run {
            let rows: [GuideRow] = try await ctx.table("repair_guides").select()
                .eq("make", value: make).order("task").limit(200).execute().value
            return rows.map(\.guide)
        }
    }

    func guides(forModel make: String, model: String) async throws -> [Guide] {
        try await ctx.run {
            let rows: [GuideRow] = try await ctx.table("repair_guides").select()
                .eq("make", value: make).eq("model", value: model).order("task").limit(200).execute().value
            return rows.map(\.guide)
        }
    }

    func search(_ query: String) async throws -> [Guide] {
        try await ctx.run {
            let rows: [GuideRow] = try await ctx.table("repair_guides").select()
                .ilike("task", pattern: "%\(filterSafe(query))%").order("task").limit(100).execute().value
            return rows.map(\.guide)
        }
    }

    func guide(_ id: GuideID) async throws -> Guide {
        try await ctx.run {
            let row: GuideRow = try await ctx.table("repair_guides").select().eq("id", value: id.key).single().execute().value
            return row.guide
        }
    }
}
