import Foundation

/// Supabase Storage buckets (section 5.5). Objects live under `<user_id>/`.
public enum MediaBucket: String, Sendable, Codable, Hashable, CaseIterable {
    case avatars, cars, posts, listings, spots, teams, messages, catalog
}

public struct StoredMedia: Hashable, Sendable, Codable {
    public var bucket: MediaBucket
    public var path: String
    public var width: Int?
    public var height: Int?
    public init(bucket: MediaBucket, path: String, width: Int? = nil, height: Int? = nil) {
        self.bucket = bucket; self.path = path; self.width = width; self.height = height
    }
}

public struct AuthSession: Hashable, Sendable {
    public var userID: UserID
    public var email: String?
    public var accessToken: String
    public var expiresAt: Date
    /// True until the profile has a handle and accepted terms (onboarding O2 and X2 pending).
    public var needsOnboarding: Bool
    public init(userID: UserID, email: String?, accessToken: String, expiresAt: Date, needsOnboarding: Bool) {
        self.userID = userID; self.email = email; self.accessToken = accessToken
        self.expiresAt = expiresAt; self.needsOnboarding = needsOnboarding
    }
}
