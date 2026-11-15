import Core
import Foundation

// STR-11 car of the week (W10-6): `car_of_week`, `car_of_week_save`, `car_of_week_board`.

private struct CarOfWeekRow: Decodable, Sendable {
    let variantId: Int64
    let label: String
}

private struct WeeklyRunRow: Decodable, Sendable {
    let userId: UUID
    let displayName: String
    let etMs: Int
    let trapMphX10: Int?
    let reactionMs: Int?
    let modelVersion: Int?
    let createdAt: Date

    var model: WeeklyRun {
        WeeklyRun(userID: UserID(raw: userId), displayName: displayName, etMs: etMs,
                  trapMphX10: trapMphX10 ?? 0, reactionMs: reactionMs ?? 0,
                  modelVersion: modelVersion ?? 1, createdAt: createdAt)
    }
}

extension LiveProgress {
    func carOfWeek() async throws -> CarOfWeekPick {
        try await ctx.run {
            let rows: [CarOfWeekRow] = try await ctx.client.rpc("car_of_week").execute().value
            guard let row = rows.first else { throw WaypointsError.notFound }
            return CarOfWeekPick(variantID: row.variantId, label: row.label)
        }
    }

    func saveCarOfWeekRun(etMs: Int, trapMphX10: Int, reactionMs: Int, modelVersion: Int) async throws {
        struct Params: Encodable, Sendable {
            let pEtMs: Int
            let pTrapMphX10: Int
            let pReactionMs: Int
            let pModelVersion: Int
        }
        try await ctx.run {
            _ = try await ctx.client.rpc("car_of_week_save",
                params: Params(pEtMs: etMs, pTrapMphX10: trapMphX10,
                               pReactionMs: reactionMs, pModelVersion: modelVersion)).execute()
        }
    }

    func carOfWeekRuns() async throws -> [WeeklyRun] {
        try await ctx.run {
            let rows: [WeeklyRunRow] = try await ctx.client.rpc("car_of_week_board").execute().value
            return rows.map(\.model)
        }
    }
}
