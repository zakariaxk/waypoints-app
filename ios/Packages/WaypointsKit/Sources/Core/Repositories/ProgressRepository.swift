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
    /// STR-11: this week's catalog car, the same for everyone.
    func carOfWeek() async throws -> CarOfWeekPick
    /// Records a car-of-the-week run; the server stamps the week and the pick.
    func saveCarOfWeekRun(etMs: Int, trapMphX10: Int, reactionMs: Int, modelVersion: Int) async throws
    /// This week's board: the caller, friends, and teammates — best run each.
    func carOfWeekRuns() async throws -> [WeeklyRun]
}
