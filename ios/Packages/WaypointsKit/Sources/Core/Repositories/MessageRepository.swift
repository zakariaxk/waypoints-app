import Foundation

/// `messages`, `threads`, `read_markers`. Section 5.4. Live delivery is Supabase Realtime.
public protocol MessageRepository: Sendable {
    /// Newest first, `limit` messages older than `before` (or the newest when `nil`).
    func messages(in target: MessageTarget, before: MessageID?, limit: Int) async throws -> [Message]
    @discardableResult func send(_ body: String, attachmentPath: String?, to target: MessageTarget) async throws -> Message
    func delete(_ id: MessageID) async throws
    /// New and changed (soft-deleted) messages in a target, as they arrive.
    func live(_ target: MessageTarget) async -> AsyncStream<Message>

    func threads() async throws -> [MessageThread]
    /// Finds or creates the DM thread with a user, or the listing thread when `listing` is set.
    func openThread(with user: UserID, listing: ListingID?) async throws -> MessageThread
    func markRead(_ target: MessageTarget, upTo id: MessageID) async throws
    /// Total unread across channels and threads, for the Teams tab badge.
    func unreadCount() async -> AsyncStream<Int>
    /// Unread messages per text channel (capped at 99), for T1 channel rows.
    func unreadCounts(in channels: [ChannelID]) async throws -> [ChannelID: Int]

    /// MSG-11: reaction counts for one page of messages (one query). Messages with none are absent.
    func reactions(for messages: [MessageID]) async throws -> [MessageID: [ReactionCount]]
    /// MSG-11: adds the caller's reaction, or removes it when `on` is false.
    func setReaction(_ reaction: Reaction, on message: MessageID, to on: Bool) async throws
    /// SAFE-12: the caller's mutes that have not run out.
    func mutes() async throws -> Set<MuteTarget>
    /// SAFE-12: mutes a target for a duration, or unmutes it when `duration` is `nil`.
    func setMute(_ target: MuteTarget, for duration: MuteDuration?) async throws
}

public extension MessageRepository {
    func unreadCounts(in channels: [ChannelID]) async throws -> [ChannelID: Int] { [:] }
}
