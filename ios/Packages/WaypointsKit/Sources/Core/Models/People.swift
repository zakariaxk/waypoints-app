import Foundation

// Section 5.1

public struct Profile: Identifiable, Hashable, Sendable, Codable {
    public var id: UserID { userID }
    public let userID: UserID
    public let uid: RealtimeUID
    public var handle: String                 // 3–20, [a-z0-9_]
    public var displayName: String            // 1–30
    public var bio: String                    // ≤160
    public var avatarPath: String?
    public var homeRegion: String?            // free text, e.g. "South Jersey"
    public var markerIcon: String             // a `MapGlyph` vehicle name, default "coupe"
    public var markerTrail: String?
    public var primaryCarID: CarID?
    public var birthYear: Int?
    public var acceptedTermsAt: Date?
    public var createdAt: Date

    public init(
        userID: UserID, uid: RealtimeUID, handle: String, displayName: String, bio: String = "",
        avatarPath: String? = nil, homeRegion: String? = nil, markerIcon: String = "coupe",
        markerTrail: String? = nil, primaryCarID: CarID? = nil, birthYear: Int? = nil,
        acceptedTermsAt: Date? = nil, createdAt: Date = .now
    ) {
        self.userID = userID; self.uid = uid; self.handle = handle; self.displayName = displayName
        self.bio = bio; self.avatarPath = avatarPath; self.homeRegion = homeRegion
        self.markerIcon = markerIcon; self.markerTrail = markerTrail; self.primaryCarID = primaryCarID
        self.birthYear = birthYear; self.acceptedTermsAt = acceptedTermsAt; self.createdAt = createdAt
    }

    public static func isValidHandle(_ handle: String) -> Bool {
        (3...20).contains(handle.count) && handle.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
    public static let minimumAge = 17
}

/// Fields the owner can change on their own profile. `nil` leaves a field unchanged.
public struct ProfileUpdate: Sendable, Codable, Hashable {
    public var handle: String?
    public var displayName: String?
    public var bio: String?
    public var avatarPath: String?
    public var homeRegion: String?
    public var markerIcon: String?
    public var markerTrail: String?
    public var primaryCarID: CarID?
    public var birthYear: Int?
    public init(
        handle: String? = nil, displayName: String? = nil, bio: String? = nil, avatarPath: String? = nil,
        homeRegion: String? = nil, markerIcon: String? = nil, markerTrail: String? = nil,
        primaryCarID: CarID? = nil, birthYear: Int? = nil
    ) {
        self.handle = handle; self.displayName = displayName; self.bio = bio; self.avatarPath = avatarPath
        self.homeRegion = homeRegion; self.markerIcon = markerIcon; self.markerTrail = markerTrail
        self.primaryCarID = primaryCarID; self.birthYear = birthYear
    }
}

public enum FriendshipStatus: String, Sendable, Codable, Hashable { case pending, accepted }

public struct Friendship: Hashable, Sendable, Codable {
    public let requesterID: UserID
    public let addresseeID: UserID
    public var status: FriendshipStatus
    public var createdAt: Date
    public init(requesterID: UserID, addresseeID: UserID, status: FriendshipStatus, createdAt: Date = .now) {
        self.requesterID = requesterID; self.addresseeID = addresseeID; self.status = status; self.createdAt = createdAt
    }
    public func other(than me: UserID) -> UserID { requesterID == me ? addresseeID : requesterID }
}

/// A friend with the profile already joined, for lists.
public struct Friend: Identifiable, Hashable, Sendable {
    public var id: UserID { profile.userID }
    public var profile: Profile
    public var primaryCar: Car?
    public var since: Date
    public init(profile: Profile, primaryCar: Car?, since: Date) {
        self.profile = profile; self.primaryCar = primaryCar; self.since = since
    }
}

public struct FriendRequest: Identifiable, Hashable, Sendable {
    public var id: UserID { profile.userID }
    public var profile: Profile
    public var sentAt: Date
    public init(profile: Profile, sentAt: Date) { self.profile = profile; self.sentAt = sentAt }
}

public struct Block: Hashable, Sendable, Codable {
    public let blockerID: UserID
    public let blockedID: UserID
    public var createdAt: Date
    public init(blockerID: UserID, blockedID: UserID, createdAt: Date = .now) {
        self.blockerID = blockerID; self.blockedID = blockedID; self.createdAt = createdAt
    }
}

public enum PrivacyLevel: String, Sendable, Codable, Hashable, CaseIterable {
    case precise, approx, hidden
}

public struct PrivacySettings: Hashable, Sendable, Codable {
    public var friendsLevel: PrivacyLevel
    public var teamLevel: PrivacyLevel
    /// Never `.precise` (section 2.5).
    public var nearbyLevel: PrivacyLevel
    public var ghostUntil: Date?
    public var notifyMeetsNearby: Bool
    public var notifyRadiusKm: Int

    public init(
        friendsLevel: PrivacyLevel = .precise, teamLevel: PrivacyLevel = .approx, nearbyLevel: PrivacyLevel = .hidden,
        ghostUntil: Date? = nil, notifyMeetsNearby: Bool = false, notifyRadiusKm: Int = 15
    ) {
        self.friendsLevel = friendsLevel; self.teamLevel = teamLevel
        self.nearbyLevel = nearbyLevel == .precise ? .approx : nearbyLevel
        self.ghostUntil = ghostUntil; self.notifyMeetsNearby = notifyMeetsNearby; self.notifyRadiusKm = notifyRadiusKm
    }

    public static let defaults = PrivacySettings()
    public func isGhost(at date: Date = .now) -> Bool { ghostUntil.map { $0 > date } ?? false }
}

/// Stored on the device only; sent to the gateway at connect (section 2.5).
public struct HomeZone: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var name: String
    public var center: Coordinate
    public var radiusMeters: Int
    public init(id: UUID = UUID(), name: String, center: Coordinate, radiusMeters: Int = HomeZone.radius) {
        self.id = id; self.name = name; self.center = center; self.radiusMeters = radiusMeters
    }
    public static let radius = 300
    public static let maximumCount = 3
}

public enum APNsEnvironment: String, Sendable, Codable, Hashable { case sandbox, production }
