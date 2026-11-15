import Foundation

/// TEAM-11: a team's place in the week's standings. `score` is the Showdown votes its members'
/// cars won since Monday 00:00 UTC.
public struct TeamStanding: Identifiable, Hashable, Sendable, Codable {
    public let id: TeamID
    public var name: String
    public var tag: String
    public var iconPath: String?
    public var score: Int
    public var rank: Int
    public init(id: TeamID, name: String, tag: String, iconPath: String? = nil, score: Int, rank: Int) {
        self.id = id; self.name = name; self.tag = tag; self.iconPath = iconPath; self.score = score; self.rank = rank
    }
}
