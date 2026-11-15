import Core
import Foundation

// GAR-18 build cost (W10-4): `build_entries.cost_cents`. `authenticated` has no SELECT on
// that column, so reads of `build_entries` name their columns and the owner reads costs
// through `build_costs(car)`.

extension LiveGarage {
    /// Every `build_entries` column a signed-in user may select: all but `cost_cents`.
    static let buildEntryColumns =
        "id,car_id,happened_on,title,body,photo_path,mod_id,is_service,odometer,odometer_unit,remind_on,created_at"

    func buildCosts(of car: CarID) async throws -> [BuildEntryID: Int] {
        struct Params: Encodable, Sendable { let car: UUID }
        struct CostRow: Decodable, Sendable { let entryId: UUID; let costCents: Int }
        return try await ctx.run {
            let rows: [CostRow] = try await ctx.client.rpc("build_costs", params: Params(car: car.raw)).execute().value
            return Dictionary(rows.map { (BuildEntryID(raw: $0.entryId), $0.costCents) }) { a, _ in a }
        }
    }

    func setBuildCost(_ id: BuildEntryID, cents: Int?) async throws {
        struct Body: Encodable, Sendable { let costCents: Nullable<Int> }
        try await ctx.run {
            _ = try await ctx.table("build_entries").update(Body(costCents: .init(cents)), returning: .minimal)
                .eq("id", value: id.key).execute()
        }
    }
}
