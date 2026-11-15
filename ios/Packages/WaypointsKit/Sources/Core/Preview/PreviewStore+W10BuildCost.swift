import Foundation

// GAR-18 build cost (W10-4).

extension PreviewSeed {
    /// Costs in cents on Maya's Mustang timeline: the intake and the coilovers.
    public static let buildCosts: [BuildEntryID: Int] = [
        buildEntries[1].id: 34_900,
        buildEntries[2].id: 129_900,
    ]
}

extension PreviewStore {
    public func buildCosts(of car: CarID) async throws -> [BuildEntryID: Int] {
        guard let me = session?.userID, cars[car]?.ownerID == me else { return [:] }
        let ids = Set(buildEntries.filter { $0.carID == car }.map(\.id))
        return buildCosts.filter { ids.contains($0.key) }
    }

    public func setBuildCost(_ id: BuildEntryID, cents: Int?) async throws {
        let me = try me()
        guard let entry = buildEntries.first(where: { $0.id == id }), cars[entry.carID]?.ownerID == me else {
            throw WaypointsError.forbidden
        }
        buildCosts[id] = cents
    }
}
