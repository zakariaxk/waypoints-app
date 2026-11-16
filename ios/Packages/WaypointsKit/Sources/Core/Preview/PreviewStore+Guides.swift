import Foundation

// Guides (section 4.26): in-memory seeds so the feature can be built before `Backend` exists.

extension PreviewStore: GuideRepository {
    var guideRows: [Guide] {
        [
            Guide(id: GuideID(raw: UUID(uuidString: "d0000000-0000-4000-8000-000000000001")!),
                  task: "Cat-back exhaust install", make: "Ford", model: "Mustang", difficulty: 3,
                  timeMinMinutes: 120, timeMaxMinutes: 240,
                  tools: ["13mm socket", "15mm socket", "ratchet", "hanger tool", "jack and stands"],
                  parts: [GuidePart(name: "Cat-back exhaust", estCostCentsLow: 40000, estCostCentsHigh: 120000)],
                  steps: ["Lift the rear and support the mufflers.", "Unbolt at the flow tubes and pull the stock system.",
                          "Fit the new system loose, align the tips, then tighten."],
                  tradeoffs: "An H-pipe keeps the classic 5.0 tone; straight-through mufflers drone at cruise.",
                  mistakes: "Tailpipe tips that touch the bumper melt plastic and rattle.",
                  sources: [URL(string: "https://www.stangnet.com/mustang-forums/")!],
                  linkedModIDs: ["catback", "h_pipe"]),
            Guide(id: GuideID(raw: UUID(uuidString: "d0000000-0000-4000-8000-000000000002")!),
                  task: "Engine oil and filter change", make: "Ford", model: "Mustang", difficulty: 1,
                  timeMinMinutes: 40, timeMaxMinutes: 80,
                  tools: ["15mm socket", "oil filter wrench", "drain pan", "jack and stands"],
                  parts: [GuidePart(name: "7 qt 5W-30 synthetic oil", estCostCentsLow: 4500, estCostCentsHigh: 7000),
                          GuidePart(name: "Oil filter", estCostCentsLow: 800, estCostCentsHigh: 1500)],
                  steps: ["Warm the engine, lift the front.", "Drain the oil and swap the filter.",
                          "Refit the plug, fill, and check the level."],
                  sources: [URL(string: "https://www.mustang6g.com/")!]),
            Guide(id: GuideID(raw: UUID(uuidString: "d0000000-0000-4000-8000-000000000003")!),
                  task: "Cold air intake install", make: "Honda", model: "Civic Type R", difficulty: 2,
                  timeMinMinutes: 45, timeMaxMinutes: 90,
                  tools: ["10mm socket", "flathead screwdriver", "trim tool"],
                  parts: [GuidePart(name: "Intake kit", estCostCentsLow: 30000, estCostCentsHigh: 55000)],
                  steps: ["Remove the front intake duct and airbox.", "Fit the new pipe, transfer the MAF.",
                          "Clamp everything and check clearances."],
                  mistakes: "A different-diameter MAF housing needs a matching tune.",
                  sources: [URL(string: "https://www.civicx.com/forum/")!],
                  linkedModIDs: ["intake_cai_turbo"]),
            Guide(id: GuideID(raw: UUID(uuidString: "d0000000-0000-4000-8000-000000000004")!),
                  task: "Brake fluid flush", make: "Subaru", model: "WRX", difficulty: 2,
                  timeMinMinutes: 60, timeMaxMinutes: 120,
                  tools: ["10mm flare wrench", "clear hose", "catch bottle", "jack and stands"],
                  parts: [GuidePart(name: "1 L DOT 4 brake fluid", estCostCentsLow: 1000, estCostCentsHigh: 2500)],
                  steps: ["Empty the reservoir and refill.", "Bleed right-rear, left-rear, right-front, left-front.",
                          "Keep the reservoir above minimum throughout."],
                  mistakes: "Letting the reservoir run dry pulls air into the ABS unit.",
                  sources: [URL(string: "https://forums.nasioc.com/")!]),
            Guide(id: GuideID(raw: UUID(uuidString: "d0000000-0000-4000-8000-000000000005")!),
                  task: "Downpipe install", make: "Subaru", model: "WRX", difficulty: 4,
                  timeMinMinutes: 180, timeMaxMinutes: 360,
                  tools: ["Socket set", "swivel extensions", "penetrating oil", "jack and stands", "O2 sensor socket"],
                  parts: [GuidePart(name: "Catted downpipe", estCostCentsLow: 40000, estCostCentsHigh: 90000),
                          GuidePart(name: "Gaskets", estCostCentsLow: 1500, estCostCentsHigh: 4000)],
                  steps: ["Soak every fastener the night before.", "Unbolt the pipe, transfer the O2 sensors.",
                          "Fit the new pipe, torque turbo-back.", "Flash the matching tune before driving."],
                  tradeoffs: "Catted keeps it streetable; catless is louder and fails visual inspection.",
                  mistakes: "A downpipe on the stock map is the classic lean-out story.",
                  sources: [URL(string: "https://www.clubwrx.net/")!],
                  linkedModIDs: ["downpipe", "tune_s2_turbo"]),
        ]
    }

    public func guidesForMake(_ make: String) async throws -> [Guide] {
        _ = try me()
        return guideRows.filter { $0.make == make }.sorted { $0.task < $1.task }
    }

    public func guides(forModel make: String, model: String) async throws -> [Guide] {
        _ = try me()
        return guideRows.filter { $0.make == make && $0.model == model }.sorted { $0.task < $1.task }
    }

    public func search(_ query: String) async throws -> [Guide] {
        _ = try me()
        let q = query.lowercased()
        return guideRows.filter { q.isEmpty || $0.task.lowercased().contains(q) }.sorted { $0.task < $1.task }
    }

    public func guide(_ id: GuideID) async throws -> Guide {
        _ = try me()
        guard let guide = guideRows.first(where: { $0.id == id }) else { throw WaypointsError.notFound }
        return guide
    }
}
