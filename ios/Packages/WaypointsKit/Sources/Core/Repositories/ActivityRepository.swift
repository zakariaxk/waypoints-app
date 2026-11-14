import Foundation

public struct ActivityID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

/// What an activity row is about (`notifications.kind`, migration W7-2).
public enum ActivityKind: String, Hashable, Sendable, Codable, CaseIterable {
    case friendRequest = "friend_request"
    case friendAccepted = "friend_accepted"
    case like, comment, mention, rsvp
    case meetChanged = "meet_changed"
    case meetNearby = "meet_nearby"
    case convoyInvite = "convoy_invite"
    case unlock
    case helpResponse = "help_response"
    /// A kind this build does not know yet.
    case other

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityKind(rawValue: raw) ?? .other
    }
}

/// One thing that happened to you (NTF-6). Kept 90 days.
public struct ActivityItem: Identifiable, Hashable, Sendable, Codable {
    public let id: ActivityID
    public var kind: ActivityKind
    public var actorID: UserID?
    /// `waypoints://` deep link to the subject.
    public var subjectURL: URL?
    public var title: String
    public var body: String?
    public var readAt: Date?
    public var createdAt: Date

    public var isUnread: Bool { readAt == nil }

    public init(id: ActivityID = ActivityID(), kind: ActivityKind, actorID: UserID? = nil, subjectURL: URL? = nil,
                title: String, body: String? = nil, readAt: Date? = nil, createdAt: Date = .now) {
        self.id = id; self.kind = kind; self.actorID = actorID; self.subjectURL = subjectURL
        self.title = title; self.body = body; self.readAt = readAt; self.createdAt = createdAt
    }
}

/// `notifications` (section 5.1, migration W7-2). Rows are written by triggers and the gateway;
/// the owner reads them and marks them read.
public protocol ActivityRepository: Sendable {
    /// Newest first.
    func recent(limit: Int) async throws -> [ActivityItem]
    func markAllRead() async throws
    /// Count of unread rows: the current value, then a new value after `recent` or `markAllRead`.
    func unreadCount() async -> AsyncStream<Int>
}
