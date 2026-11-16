import Foundation

public struct GuideID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

/// A part line in `repair_guides.parts`, costs in cents.
public struct GuidePart: Hashable, Sendable, Codable {
    public var name: String
    public var estCostCentsLow: Int
    public var estCostCentsHigh: Int
    public var partNumber: String?
    public init(name: String, estCostCentsLow: Int, estCostCentsHigh: Int, partNumber: String? = nil) {
        self.name = name; self.estCostCentsLow = estCostCentsLow; self.estCostCentsHigh = estCostCentsHigh
        self.partNumber = partNumber
    }
}

/// `repair_guides` (section 4.26, KNW-1): a curated how-to. Readable by any signed-in user;
// written only by the pipeline, so the repository is read-only.
public struct Guide: Identifiable, Hashable, Sendable, Codable {
    public let id: GuideID
    public var task: String
    public var make: String
    public var model: String?
    /// Key into the bundled catalog snapshot (`cars.catalog_variant_id`), not a database FK.
    public var variantID: Int64?
    /// 1 (easy) to 5 (hard).
    public var difficulty: Int
    public var timeMinMinutes: Int
    public var timeMaxMinutes: Int
    public var tools: [String]
    public var parts: [GuidePart]
    /// Ordered.
    public var steps: [String]
    public var tradeoffs: String?
    public var mistakes: String?
    public var sources: [URL]
    /// PerformanceModel mod keys this task installs (KNW-4, "Simulate this").
    public var linkedModIDs: [String]
    /// KNW-8: people who found this guide helpful. Trigger-maintained `repair_guides.votes_count`.
    public var votesCount: Int
    /// KNW-8: the viewer's own row in `guide_votes`.
    public var votedByMe: Bool
    public var createdAt: Date

    public init(id: GuideID, task: String, make: String, model: String? = nil, variantID: Int64? = nil,
                difficulty: Int, timeMinMinutes: Int, timeMaxMinutes: Int, tools: [String] = [],
                parts: [GuidePart] = [], steps: [String] = [], tradeoffs: String? = nil,
                mistakes: String? = nil, sources: [URL] = [], linkedModIDs: [String] = [],
                votesCount: Int = 0, votedByMe: Bool = false, createdAt: Date = .now) {
        self.id = id; self.task = task; self.make = make; self.model = model; self.variantID = variantID
        self.difficulty = difficulty; self.timeMinMinutes = timeMinMinutes; self.timeMaxMinutes = timeMaxMinutes
        self.tools = tools; self.parts = parts; self.steps = steps; self.tradeoffs = tradeoffs
        self.mistakes = mistakes; self.sources = sources; self.linkedModIDs = linkedModIDs
        self.votesCount = votesCount; self.votedByMe = votedByMe
        self.createdAt = createdAt
    }

    /// "Honda S2000", or the make alone for guides that cover the whole make.
    public var vehicleLabel: String { [make, model].compactMap { $0 }.joined(separator: " ") }
}

public protocol GuideRepository: Sendable {
    /// Every guide for a make, task A to Z (KNW-2 "For your cars").
    func guidesForMake(_ make: String) async throws -> [Guide]
    /// Guides matching make and model exactly.
    func guides(forModel make: String, model: String) async throws -> [Guide]
    /// Task search, case-insensitive substring (KNW-2).
    func search(_ query: String) async throws -> [Guide]
    func guide(_ id: GuideID) async throws -> Guide
    /// KNW-8: mark a guide helpful. Idempotent.
    func vote(_ id: GuideID) async throws
    func unvote(_ id: GuideID) async throws
}
