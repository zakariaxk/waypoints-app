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
}
