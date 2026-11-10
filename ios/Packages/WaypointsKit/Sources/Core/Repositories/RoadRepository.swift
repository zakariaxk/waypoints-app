import Foundation

/// `roads`, `road_ratings`. Section 5.3.
public protocol RoadRepository: Sendable {
    /// `roads_in_bbox`.
    func roads(in region: MapRegion) async throws -> [Road]
    func road(_ id: RoadID) async throws -> Road
    func roads(by author: UserID) async throws -> [Road]
    @discardableResult func createRoad(name: String, path: [Coordinate]) async throws -> Road
    func rate(_ road: RoadID, _ rating: RoadRating) async throws
    func myRating(for road: RoadID) async throws -> RoadRating?
}
