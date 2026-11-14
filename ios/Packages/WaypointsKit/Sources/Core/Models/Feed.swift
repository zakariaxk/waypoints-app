import Foundation

// Section 5.5: feed and Showdown

public struct Post: Identifiable, Hashable, Sendable, Codable {
    public let id: PostID
    public let authorID: UserID
    public var carID: CarID?
    /// The meet the post was tagged with (FEED-11).
    public var meetID: MeetID?
    /// Nil for a photo post.
    public var videoPath: String?
    /// A photo post's photos in order, at most `Post.maxPhotos` (FEED-11). Empty for a video post.
    public var photoPaths: [String]
    public var posterPath: String
    public var caption: String                // ≤150
    public var durationMs: Int
    public var likeCount: Int
    public var commentCount: Int
    public var likedByMe: Bool
    public var createdAt: Date
    public init(id: PostID = PostID(), authorID: UserID, carID: CarID? = nil, meetID: MeetID? = nil, videoPath: String?,
                photoPaths: [String] = [], posterPath: String,
                caption: String = "", durationMs: Int, likeCount: Int = 0, commentCount: Int = 0,
                likedByMe: Bool = false, createdAt: Date = .now) {
        self.id = id; self.authorID = authorID; self.carID = carID; self.meetID = meetID; self.videoPath = videoPath
        self.photoPaths = photoPaths; self.posterPath = posterPath; self.caption = caption; self.durationMs = durationMs
        self.likeCount = likeCount; self.commentCount = commentCount; self.likedByMe = likedByMe
        self.createdAt = createdAt
    }

    /// FEED-11: a photo post carries up to 6 photos.
    public static let maxPhotos = 6
    public var isPhotoPost: Bool { videoPath == nil && !photoPaths.isEmpty }
}

/// Either `videoPath` or one to six `photoPaths` (FEED-11).
public struct NewPost: Hashable, Sendable, Codable {
    public var carID: CarID?
    public var meetID: MeetID?
    public var videoPath: String?
    public var photoPaths: [String]
    public var posterPath: String
    public var caption: String
    public var durationMs: Int                // 0 for a photo post
    public init(carID: CarID? = nil, meetID: MeetID? = nil, videoPath: String?, photoPaths: [String] = [],
                posterPath: String, caption: String, durationMs: Int) {
        self.carID = carID; self.meetID = meetID; self.videoPath = videoPath; self.photoPaths = photoPaths
        self.posterPath = posterPath; self.caption = caption; self.durationMs = durationMs
    }
}

public struct PostComment: Identifiable, Hashable, Sendable, Codable {
    public let id: CommentID
    public let postID: PostID
    public let authorID: UserID
    public var body: String                   // ≤300
    public var createdAt: Date
    public init(id: CommentID = CommentID(), postID: PostID, authorID: UserID, body: String, createdAt: Date = .now) {
        self.id = id; self.postID = postID; self.authorID = authorID; self.body = body; self.createdAt = createdAt
    }
}

/// Opaque pagination cursor. Repositories decide what it encodes.
public struct PageCursor: Hashable, Sendable, Codable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var next: PageCursor?
    public init(items: [Item], next: PageCursor?) { self.items = items; self.next = next }
}

public enum ShowdownClass: String, Sendable, Codable, Hashable, CaseIterable { case street, built, show, classic }

public struct ShowdownEntry: Hashable, Sendable, Codable {
    public let carID: CarID
    public var rating: Int
    public var wins: Int
    public var losses: Int
    public var showdownClass: ShowdownClass
    public init(carID: CarID, rating: Int = 1200, wins: Int = 0, losses: Int = 0, showdownClass: ShowdownClass) {
        self.carID = carID; self.rating = rating; self.wins = wins; self.losses = losses; self.showdownClass = showdownClass
    }
}

/// A car with what Showdown needs to show it.
public struct ShowdownContender: Hashable, Sendable {
    public var car: Car
    public var owner: Profile
    public var photos: [CarPhoto]
    public var entry: ShowdownEntry
    public init(car: Car, owner: Profile, photos: [CarPhoto], entry: ShowdownEntry) {
        self.car = car; self.owner = owner; self.photos = photos; self.entry = entry
    }
}

public struct ShowdownPair: Hashable, Sendable {
    public var left: ShowdownContender
    public var right: ShowdownContender
    public init(left: ShowdownContender, right: ShowdownContender) { self.left = left; self.right = right }
}

public enum RankingPeriod: String, Sendable, Codable, Hashable { case week, allTime }
