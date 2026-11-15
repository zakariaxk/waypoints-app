import Foundation

// W10-7 (TEAM-11): team standings.

extension PreviewSeed {
    /// Showdown votes each car won this week.
    static let weekWins: [CarID: Int] = [car(1): 9, car(4): 14, car(5): 11, car(6): 17, car(9): 6, car(10): 4]
}

extension PreviewStore {
    public func standings(including team: TeamID?) async throws -> [TeamStanding] {
        let me = try me()
        var scores: [TeamID: Int] = [:]
        for car in cars.values {
            guard let wins = PreviewSeed.weekWins[car.id] else { continue }
            for m in members where m.userID == car.ownerID { scores[m.teamID, default: 0] += wins }
        }
        var list: [TeamStanding] = []
        for (id, score) in scores {
            guard let t = teams[id], t.isPublic || isMember(id, me) else { continue }
            let rank = 1 + scores.values.filter { $0 > score }.count
            list.append(TeamStanding(id: id, name: t.name, tag: t.tag, iconPath: t.iconPath, score: score, rank: rank))
        }
        return list.sorted { ($0.rank, $0.name) < ($1.rank, $1.name) }
    }
}
