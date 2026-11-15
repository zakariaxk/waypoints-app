import Foundation

extension PreviewSeed {
    /// MOD-15: two builds on Maya's Mustang, so the comparison is visible in preview.
    static let savedBuilds: [CarID: [SavedBuild]] = [
        car(1): [
            SavedBuild(id: uuid(1, 20), name: "Street", mods: ["catback", "intake_cai_na"]),
            SavedBuild(id: uuid(2, 20), name: "Track day", mods: ["catback", "headers_lt", "intake_cai_na", "tune_s1_na"]),
        ],
    ]
}

extension PreviewStore {
    public func savedBuilds(for car: CarID) async throws -> [SavedBuild] {
        guard let owner = cars[car]?.ownerID, visible(owner) else { throw WaypointsError.notFound }
        return savedBuilds[car] ?? []
    }
    public func setSavedBuilds(_ builds: [SavedBuild], for car: CarID) async throws {
        let me = try me()
        guard cars[car]?.ownerID == me, builds.count <= SavedBuild.limit else { throw WaypointsError.forbidden }
        savedBuilds[car] = builds
    }
}
