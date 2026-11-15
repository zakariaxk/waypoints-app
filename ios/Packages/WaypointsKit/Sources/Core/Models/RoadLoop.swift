import Foundation

public struct LoopID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

/// ROAD-6: saved roads grouped in driving order under a name (`road_loops`). Private to its
/// owner; anyone signed in who has the id (a share link) can read it.
public struct RoadLoop: Identifiable, Hashable, Sendable, Codable {
    public let id: LoopID
    public var ownerID: UserID
    public var name: String
    public var roadIDs: [RoadID]
    public var createdAt: Date
    public init(id: LoopID = LoopID(), ownerID: UserID, name: String, roadIDs: [RoadID], createdAt: Date = .now) {
        self.id = id; self.ownerID = ownerID; self.name = name; self.roadIDs = roadIDs; self.createdAt = createdAt
    }
}
