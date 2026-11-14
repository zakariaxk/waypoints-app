import Foundation

/// `posts`, `post_likes`, `post_comments`, `follows`. Section 5.5.
public protocol PostRepository: Sendable {
    /// "For you": RPC `feed_for_you`, recency plus likes in the viewer's region, then everywhere.
    func forYou(after cursor: PageCursor?, limit: Int) async throws -> Page<Post>
    /// "Following": posts by the people the viewer follows, newest first.
    func followingFeed(after cursor: PageCursor?, limit: Int) async throws -> Page<Post>
    func posts(by author: UserID) async throws -> [Post]
    func post(_ id: PostID) async throws -> Post
    @discardableResult func createPost(_ post: NewPost) async throws -> Post
    func deletePost(_ id: PostID) async throws
    func like(_ id: PostID) async throws
    func unlike(_ id: PostID) async throws

    func comments(on post: PostID) async throws -> [PostComment]
    @discardableResult func addComment(_ body: String, to post: PostID) async throws -> PostComment
    func deleteComment(_ id: CommentID) async throws

    func follow(_ user: UserID) async throws
    func unfollow(_ user: UserID) async throws
    func isFollowing(_ user: UserID) async throws -> Bool
}
