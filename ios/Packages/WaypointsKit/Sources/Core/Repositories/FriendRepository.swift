import Foundation

/// `friendships`. Section 5.1. Only the addressee can accept.
public protocol FriendRepository: Sendable {
    func friends() async throws -> [Friend]
    func incomingRequests() async throws -> [FriendRequest]
    func outgoingRequests() async throws -> [FriendRequest]
    func friendship(with user: UserID) async throws -> Friendship?
    func sendRequest(to user: UserID) async throws
    func acceptRequest(from user: UserID) async throws
    /// Declines a request, cancels one you sent, or removes a friend.
    func remove(_ user: UserID) async throws
    /// Emits the friend list whenever it changes.
    func friendChanges() async -> AsyncStream<[Friend]>
}
