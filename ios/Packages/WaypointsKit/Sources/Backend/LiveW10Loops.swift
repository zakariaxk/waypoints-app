import Core
import Foundation

// ROAD-6 loops (W10-9): `road_loops`, owner-only by RLS; `road_loop(p_id)` answers for a
// loop shared by link.

private struct RoadLoopRow: Decodable, Sendable {
    let id: UUID
    let ownerId: UUID
    let name: String
    let roadIds: [UUID]
    let createdAt: Date

    var model: RoadLoop {
        RoadLoop(id: LoopID(raw: id), ownerID: UserID(raw: ownerId), name: name,
                 roadIDs: roadIds.map(RoadID.init(raw:)), createdAt: createdAt)
    }
}

extension LiveRoads {
    func myLoops() async throws -> [RoadLoop] {
        let me = try ctx.me()
        return try await ctx.run {
            let rows: [RoadLoopRow] = try await ctx.table("road_loops").select().eq("owner_id", value: me.key)
                .order("created_at", ascending: false).execute().value
            return rows.map(\.model)
        }
    }

    func loop(_ id: LoopID) async throws -> RoadLoop {
        struct Params: Encodable { let pId: UUID }
        return try await ctx.run {
            let rows: [RoadLoopRow] = try await ctx.client.rpc("road_loop", params: Params(pId: id.raw)).execute().value
            guard let row = rows.first else { throw WaypointsError.notFound }
            return row.model
        }
    }

    func saveLoop(_ loop: RoadLoop) async throws -> RoadLoop {
        struct Body: Encodable { let id: UUID; let ownerId: UUID; let name: String; let roadIds: [UUID] }
        return try await ctx.run {
            let row: RoadLoopRow = try await ctx.table("road_loops")
                .upsert(Body(id: loop.id.raw, ownerId: loop.ownerID.raw, name: loop.name, roadIds: loop.roadIDs.map(\.raw)))
                .select().single().execute().value
            return row.model
        }
    }

    func deleteLoop(_ id: LoopID) async throws {
        try await ctx.run {
            _ = try await ctx.table("road_loops").delete(returning: .minimal).eq("id", value: id.key).execute()
        }
    }
}
