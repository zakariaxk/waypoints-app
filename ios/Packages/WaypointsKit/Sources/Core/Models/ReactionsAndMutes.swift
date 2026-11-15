import Foundation

/// MSG-11: the six fixed reactions. The raw value is `message_reactions.reaction`.
public enum Reaction: String, CaseIterable, Sendable, Codable, Hashable {
    case fire, heart, thumbsUp = "thumbs_up", laugh, flag, wrench

    public var glyph: String {
        switch self {
        case .fire: "🔥"
        case .heart: "❤️"
        case .thumbsUp: "👍"
        case .laugh: "😂"
        case .flag: "🏁"
        case .wrench: "🔧"
        }
    }
}

/// One reaction's count on a message, and whether the signed-in user is in it.
public struct ReactionCount: Hashable, Sendable {
    public let reaction: Reaction
    public var count: Int
    public var mine: Bool
    public init(reaction: Reaction, count: Int, mine: Bool) {
        self.reaction = reaction; self.count = count; self.mine = mine
    }
}

/// SAFE-12: what can be muted. `mutes.target_kind` and `target_id`.
public enum MuteTarget: Hashable, Sendable {
    case user(UserID)
    case thread(ThreadID)
    case channel(ChannelID)
    case team(TeamID)
}

/// SAFE-12: how long a mute lasts.
public enum MuteDuration: CaseIterable, Sendable, Hashable {
    case eightHours, week, untilTurnedOn

    /// When the mute ends; `nil` is until turned back on.
    public func end(from now: Date = .now) -> Date? {
        switch self {
        case .eightHours: now.addingTimeInterval(8 * 3600)
        case .week: now.addingTimeInterval(7 * 86400)
        case .untilTurnedOn: nil
        }
    }
}
