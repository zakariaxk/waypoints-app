import Foundation

// Section 5.5: achievements, race results. Keys and unlocks: section 9.8.

public struct Achievement: Hashable, Sendable, Codable {
    public let userID: UserID
    public let key: String
    public var earnedAt: Date
    public init(userID: UserID, key: String, earnedAt: Date = .now) {
        self.userID = userID; self.key = key; self.earnedAt = earnedAt
    }
}

/// Progress toward one achievement key, e.g. "Rally: get 10 reports confirmed. You're at 6."
public struct AchievementProgress: Hashable, Sendable, Codable {
    public let key: String
    public var current: Int
    public var target: Int
    public var earnedAt: Date?
    public init(key: String, current: Int, target: Int, earnedAt: Date? = nil) {
        self.key = key; self.current = current; self.target = target; self.earnedAt = earnedAt
    }
}

public struct RaceResult: Identifiable, Hashable, Sendable, Codable {
    public let id: RaceResultID
    public let userID: UserID
    public let carID: CarID
    public var mods: [String]
    public var reactionMs: Int
    public var etMs: Int
    public var trapMphX10: Int
    public var sixtyFtMs: Int
    public var inputLog: Data                 // ghost replay, ≤4 KB
    public var createdAt: Date
    public init(id: RaceResultID = RaceResultID(), userID: UserID, carID: CarID, mods: [String], reactionMs: Int,
                etMs: Int, trapMphX10: Int, sixtyFtMs: Int, inputLog: Data, createdAt: Date = .now) {
        self.id = id; self.userID = userID; self.carID = carID; self.mods = mods; self.reactionMs = reactionMs
        self.etMs = etMs; self.trapMphX10 = trapMphX10; self.sixtyFtMs = sixtyFtMs; self.inputLog = inputLog
        self.createdAt = createdAt
    }
}
