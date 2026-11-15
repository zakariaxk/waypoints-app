import Core
import Foundation
import Supabase

// W10-7 (TEAM-11): team standings.

extension LiveTeams {
    func standings(including team: TeamID?) async throws -> [TeamStanding] {
        struct Params: Encodable { let team: UUID? }
        struct Row: Decodable { let teamId: UUID; let name: String; let tag: String; let iconPath: String?; let score: Int; let rank: Int }
        let rows: [Row] = try await ctx.run {
            try await ctx.client.rpc("team_standings", params: Params(team: team?.raw)).execute().value
        }
        return rows.map {
            TeamStanding(id: TeamID(raw: $0.teamId), name: $0.name, tag: $0.tag, iconPath: $0.iconPath, score: $0.score, rank: $0.rank)
        }
    }
}
