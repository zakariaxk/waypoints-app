import Foundation

/// `reports` (read). Section 5.3. Posting and voting go through `GatewayService`.
public protocol ReportRepository: Sendable {
    /// `reports_in_bbox`: only unexpired reports.
    func reports(in region: MapRegion) async throws -> [Report]
    func report(_ id: ReportID) async throws -> Report
    /// `hazards_along`: reports within `bufferMeters` of a route.
    func hazards(along path: [Coordinate], bufferMeters: Int) async throws -> [Report]
    func myVote(on report: ReportID) async throws -> Bool?
}
