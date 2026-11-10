import Foundation

// Section 5.4

public struct Team: Identifiable, Hashable, Sendable, Codable {
    public let id: TeamID
    public let ownerID: UserID
    public var name: String                   // ≤40
    public var tag: String                    // 2–5 caps, unique
    public var about: String                  // ≤300
    public var iconPath: String?
    public var isPublic: Bool
    public var inviteCode: String?
    public var memberCount: Int
    public var createdAt: Date
    public init(id: TeamID = TeamID(), ownerID: UserID, name: String, tag: String, about: String = "",
                iconPath: String? = nil, isPublic: Bool = true, inviteCode: String? = nil, memberCount: Int = 1,
                createdAt: Date = .now) {
        self.id = id; self.ownerID = ownerID; self.name = name; self.tag = tag; self.about = about
        self.iconPath = iconPath; self.isPublic = isPublic; self.inviteCode = inviteCode
        self.memberCount = memberCount; self.createdAt = createdAt
    }
}

public struct TeamDraft: Hashable, Sendable, Codable {
    public var name: String
    public var tag: String
    public var about: String
    public var iconPath: String?
    public var isPublic: Bool
    public init(name: String, tag: String, about: String = "", iconPath: String? = nil, isPublic: Bool = true) {
        self.name = name; self.tag = tag; self.about = about; self.iconPath = iconPath; self.isPublic = isPublic
    }
}

public struct TeamPermissions: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let manageTeam = TeamPermissions(rawValue: 1)
    public static let manageChannels = TeamPermissions(rawValue: 2)
    public static let manageRoles = TeamPermissions(rawValue: 4)
    public static let kick = TeamPermissions(rawValue: 8)
    public static let deleteMessages = TeamPermissions(rawValue: 16)
    public static let hostMeets = TeamPermissions(rawValue: 32)
    public static let all: TeamPermissions = [.manageTeam, .manageChannels, .manageRoles, .kick, .deleteMessages, .hostMeets]
}

public struct TeamRole: Identifiable, Hashable, Sendable, Codable {
    public let id: TeamRoleID
    public let teamID: TeamID
    public var name: String
    public var colorHex: String?
    public var rank: Int
    public var permissions: TeamPermissions
    public init(id: TeamRoleID = TeamRoleID(), teamID: TeamID, name: String, colorHex: String? = nil, rank: Int,
                permissions: TeamPermissions) {
        self.id = id; self.teamID = teamID; self.name = name; self.colorHex = colorHex; self.rank = rank
        self.permissions = permissions
    }
}

public struct TeamMember: Hashable, Sendable, Codable {
    public let teamID: TeamID
    public let userID: UserID
    public var roleID: TeamRoleID?
    public var joinedAt: Date
    public init(teamID: TeamID, userID: UserID, roleID: TeamRoleID? = nil, joinedAt: Date = .now) {
        self.teamID = teamID; self.userID = userID; self.roleID = roleID; self.joinedAt = joinedAt
    }
}

public enum ChannelKind: String, Sendable, Codable, Hashable { case text, voice }

public struct Channel: Identifiable, Hashable, Sendable, Codable {
    public let id: ChannelID
    public let teamID: TeamID
    public var name: String                   // ≤30, lowercase, hyphens
    public var kind: ChannelKind
    public var sort: Int
    public init(id: ChannelID = ChannelID(), teamID: TeamID, name: String, kind: ChannelKind, sort: Int = 0) {
        self.id = id; self.teamID = teamID; self.name = name; self.kind = kind; self.sort = sort
    }
}

public enum ThreadKind: String, Sendable, Codable, Hashable { case dm, listing }

public struct MessageThread: Identifiable, Hashable, Sendable, Codable {
    public let id: ThreadID
    public var kind: ThreadKind
    public var listingID: ListingID?
    public var aID: UserID
    public var bID: UserID
    public var lastMessage: Message?
    public var unreadCount: Int
    public var createdAt: Date
    public init(id: ThreadID = ThreadID(), kind: ThreadKind, listingID: ListingID? = nil, aID: UserID, bID: UserID,
                lastMessage: Message? = nil, unreadCount: Int = 0, createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.listingID = listingID; self.aID = aID; self.bID = bID
        self.lastMessage = lastMessage; self.unreadCount = unreadCount; self.createdAt = createdAt
    }
    public func other(than me: UserID) -> UserID { aID == me ? bID : aID }
}

/// Where a message lives: exactly one of channel or thread (section 5.4).
public enum MessageTarget: Hashable, Sendable, Codable {
    case channel(ChannelID)
    case thread(ThreadID)
}

public struct Message: Identifiable, Hashable, Sendable, Codable {
    public let id: MessageID
    public let target: MessageTarget
    public let authorID: UserID
    public var body: String                   // ≤2000
    public var attachmentPath: String?
    public var deletedAt: Date?
    public var createdAt: Date
    public init(id: MessageID, target: MessageTarget, authorID: UserID, body: String, attachmentPath: String? = nil,
                deletedAt: Date? = nil, createdAt: Date = .now) {
        self.id = id; self.target = target; self.authorID = authorID; self.body = body
        self.attachmentPath = attachmentPath; self.deletedAt = deletedAt; self.createdAt = createdAt
    }
}

public struct ReadMarker: Hashable, Sendable, Codable {
    public let target: MessageTarget
    public var lastReadMessageID: MessageID
    public init(target: MessageTarget, lastReadMessageID: MessageID) {
        self.target = target; self.lastReadMessageID = lastReadMessageID
    }
}
