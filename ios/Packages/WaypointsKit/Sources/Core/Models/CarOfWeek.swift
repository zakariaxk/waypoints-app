import Foundation

/// STR-11: the catalog car everyone runs this week. Same pick for everyone, stock,
/// resetting every Monday 00:00 UTC. `variantID` resolves in the bundled catalog;
/// `label` is the fallback when a catalog rebuild dropped the row.
public struct CarOfWeekPick: Hashable, Sendable {
    public var variantID: Int64
    public var label: String
    public init(variantID: Int64, label: String) {
        self.variantID = variantID
        self.label = label
    }
}

/// One driver's best run in this week's car, on the weekly board. Only the caller,
/// their friends, and their teammates appear (`car_of_week_board`).
public struct WeeklyRun: Hashable, Sendable, Identifiable {
    public var userID: UserID
    public var displayName: String
    public var etMs: Int
    public var trapMphX10: Int
    public var reactionMs: Int
    public var modelVersion: Int
    public var createdAt: Date
    public var id: UserID { userID }
    public init(userID: UserID, displayName: String, etMs: Int, trapMphX10: Int,
                reactionMs: Int, modelVersion: Int, createdAt: Date) {
        self.userID = userID
        self.displayName = displayName
        self.etMs = etMs
        self.trapMphX10 = trapMphX10
        self.reactionMs = reactionMs
        self.modelVersion = modelVersion
        self.createdAt = createdAt
    }
}
