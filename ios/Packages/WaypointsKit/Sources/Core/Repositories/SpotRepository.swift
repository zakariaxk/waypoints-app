import Foundation

/// `spots`. Section 5.3. Location is city level only.
public protocol SpotRepository: Sendable {
    func spots(by spotter: UserID) async throws -> [Spot]
    @discardableResult func addSpot(_ spot: Spot) async throws -> Spot
    func deleteSpot(_ id: SpotID) async throws
}
