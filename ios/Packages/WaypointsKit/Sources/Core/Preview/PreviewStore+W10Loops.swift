import Foundation

// ROAD-6 loops (W10-9).

public extension PreviewSeed {
    static let roadLoop = RoadLoop(id: LoopID(raw: uuid(1, 16)), ownerID: me, name: "Pine Barrens loop",
                                   roadIDs: [roads[1].id, roads[0].id, roads[2].id], createdAt: hours(-24 * 3))
}

extension PreviewStore {
    public func myLoops() async throws -> [RoadLoop] {
        let me = try me()
        return roadLoops.values.filter { $0.ownerID == me }.sorted { $0.createdAt > $1.createdAt }
    }
    public func loop(_ id: LoopID) async throws -> RoadLoop {
        guard let loop = roadLoops[id], visible(loop.ownerID) else { throw WaypointsError.notFound }
        return loop
    }
    public func saveLoop(_ loop: RoadLoop) async throws -> RoadLoop {
        let me = try me()
        guard loop.ownerID == me else { throw WaypointsError.forbidden }
        roadLoops[loop.id] = loop
        return loop
    }
    public func deleteLoop(_ id: LoopID) async throws {
        let me = try me()
        guard roadLoops[id]?.ownerID == me else { throw WaypointsError.forbidden }
        roadLoops[id] = nil
    }
}
