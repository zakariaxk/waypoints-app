import Foundation

/// `showdown_entries`, `showdown_votes`. Section 5.5.
public protocol ShowdownRepository: Sendable {
    func entry(for car: CarID) async throws -> ShowdownEntry?
    /// Requires at least one photo on the car.
    @discardableResult func enter(_ car: CarID, class showdownClass: ShowdownClass) async throws -> ShowdownEntry
    func withdraw(_ car: CarID) async throws
    /// A pair the user has not voted on and owns neither of; `nil` when none are left.
    func nextPair(in showdownClass: ShowdownClass) async throws -> ShowdownPair?
    /// RPC `cast_showdown_vote(winner, loser)`.
    func vote(winner: CarID, loser: CarID) async throws
    func rankings(in showdownClass: ShowdownClass, period: RankingPeriod, limit: Int) async throws -> [ShowdownContender]
}
