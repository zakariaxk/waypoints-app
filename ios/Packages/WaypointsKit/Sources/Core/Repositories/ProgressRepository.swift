import Foundation

/// `achievements`, `race_results`. Section 5.5; keys in section 9.8.
public protocol ProgressRepository: Sendable {
    func achievements(of user: UserID) async throws -> [Achievement]
    /// Progress toward every key for the signed-in user, earned or not.
    func myProgress() async throws -> [AchievementProgress]
    @discardableResult func saveRaceResult(_ result: RaceResult) async throws -> RaceResult
    func raceResults(for car: CarID) async throws -> [RaceResult]
    func bestRaceResults(limit: Int) async throws -> [RaceResult]
    /// Another user's fastest runs (the Strip's "A friend's run").
    func raceResults(by user: UserID, limit: Int) async throws -> [RaceResult]
}
