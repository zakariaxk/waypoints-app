import Foundation

/// In-memory `ActivityRepository` (W7-2) with a few rows about `PreviewSeed.me`.
public actor PreviewActivity: ActivityRepository {
    /// Shared instance the app uses when there is no backend.
    public static let shared = PreviewActivity()

    var items: [ActivityItem]
    var unread = Broadcast<Int>()

    public init(items: [ActivityItem] = PreviewActivity.seed) { self.items = items }

    public func recent(limit: Int) async throws -> [ActivityItem] {
        Array(items.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    public func markAllRead() async throws {
        let now = Date.now
        for index in items.indices where items[index].readAt == nil { items[index].readAt = now }
        unread.send(0)
    }

    public func unreadCount() async -> AsyncStream<Int> {
        unread.subscribe(initial: items.filter(\.isUnread).count)
    }

    public static let seed: [ActivityItem] = {
        let s = PreviewSeed.self
        func link(_ path: String) -> URL? { URL(string: "waypoints://\(path)") }
        return [
            ActivityItem(kind: .friendRequest, actorID: s.theo, subjectURL: link("profile/\(s.theo)"),
                         title: "Friend request", body: "Theo Kowalski wants to be friends.", createdAt: s.hours(-0.2)),
            ActivityItem(kind: .rsvp, actorID: s.jae, subjectURL: link("meet/\(s.meets[0].id)"),
                         title: "Jae Park is going", body: s.meets[0].title, createdAt: s.hours(-1.5)),
            ActivityItem(kind: .meetChanged, subjectURL: link("meet/\(s.meets[1].id)"),
                         title: s.meets[1].title, body: "New time: Sat 9:30 AM", readAt: s.hours(-20), createdAt: s.hours(-26)),
            ActivityItem(kind: .friendAccepted, actorID: s.devon, subjectURL: link("profile/\(s.devon)"),
                         title: "Friend request accepted", body: "Devon Price accepted your friend request.",
                         readAt: s.hours(-40), createdAt: s.hours(-48)),
            ActivityItem(kind: .unlock, subjectURL: link("profile/\(s.me)"), title: "New marker earned",
                         readAt: s.hours(-70), createdAt: s.hours(-72)),
        ]
    }()
}
