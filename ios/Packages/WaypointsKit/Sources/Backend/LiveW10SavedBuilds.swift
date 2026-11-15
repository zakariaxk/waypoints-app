import Core
import Foundation
import Supabase

/// MOD-15: `cars.saved_builds`. Read and written on its own so `updateCar` never touches it.
extension LiveGarage {
    func savedBuilds(for car: CarID) async throws -> [SavedBuild] {
        struct Row: Decodable, Sendable { let savedBuilds: [SavedBuild] }
        return try await ctx.run {
            let row: Row = try await ctx.table("cars").select("saved_builds").eq("id", value: car.key)
                .single().execute().value
            return row.savedBuilds
        }
    }

    func setSavedBuilds(_ builds: [SavedBuild], for car: CarID) async throws {
        struct Body: Encodable, Sendable { let savedBuilds: [SavedBuild] }
        struct Row: Decodable, Sendable { let id: UUID }
        try await ctx.run {
            // `single()` turns "no row updated" (not the owner) into an error.
            let _: Row = try await ctx.table("cars").update(Body(savedBuilds: builds)).eq("id", value: car.key)
                .select("id").single().execute().value
        }
    }
}
