import Foundation

// STR-11 car of the week (W10-6).

/// The preview pick resolves in `PreviewSeed.catalogVariants` (id 1001, the 2019 Mustang
/// GT), and the board seeds you, a friend, and a teammate — lena shares a team but is
/// not a friend, so both paths show.
enum PreviewCarOfWeek {
    static let pick = CarOfWeekPick(variantID: 1001, label: "2019 Ford Mustang GT")

    static func run(_ user: UserID, _ etMs: Int, _ hoursAgo: Double) -> WeeklyRun {
        let name = PreviewSeed.profiles.first { $0.userID == user }?.displayName ?? "Driver"
        // PerformanceModelVersion.current is 2; Core cannot see that type, so the seed
        // pins the literal the Strip filters on.
        return WeeklyRun(userID: user, displayName: name, etMs: etMs, trapMphX10: etMs / 10,
                         reactionMs: 400, modelVersion: 2,
                         createdAt: PreviewSeed.hours(hoursAgo))
    }

    static let runs: [WeeklyRun] = [
        run(PreviewSeed.maya, 12800, -30),
        run(PreviewSeed.maya, 13100, -50),       // a slower earlier run; the best wins
        run(PreviewSeed.devon, 11450, -20),
        run(PreviewSeed.jae, 15100, -10),
        run(PreviewSeed.lena, 11980, -5),
    ]
}

extension PreviewStore {
    public func carOfWeek() async throws -> CarOfWeekPick { PreviewCarOfWeek.pick }

    public func saveCarOfWeekRun(etMs: Int, trapMphX10: Int, reactionMs: Int, modelVersion: Int) async throws {
        let me = try me()
        guard (4000...60000).contains(etMs) else { throw WaypointsError.invalid("etMs") }
        let name = profiles[me]?.displayName ?? ""
        weeklyRuns.append(WeeklyRun(userID: me, displayName: name, etMs: etMs,
                                    trapMphX10: trapMphX10, reactionMs: reactionMs,
                                    modelVersion: modelVersion, createdAt: .now))
    }

    /// The board: best run per person, the caller, friends, and teammates only.
    public func carOfWeekRuns() async throws -> [WeeklyRun] {
        let me = try me()
        var best: [UserID: WeeklyRun] = [:]
        for r in weeklyRuns where (best[r.userID]?.etMs ?? Int.max) > r.etMs {
            best[r.userID] = r
        }
        let friendIDs = Set(friendships
            .filter { $0.status == .accepted && ($0.requesterID == me || $0.addresseeID == me) }
            .map { $0.other(than: me) })
        let myTeams = Set(members.filter { $0.userID == me }.map(\.teamID))
        let mateIDs = Set(members.filter { myTeams.contains($0.teamID) }.map(\.userID))
        return best.values
            .filter { r in
                r.userID == me
                    || (!isBlockedEitherWay(me, r.userID) && (friendIDs.contains(r.userID) || mateIDs.contains(r.userID)))
            }
            .sorted { $0.etMs < $1.etMs }
            .prefix(100).map { $0 }
    }
}
