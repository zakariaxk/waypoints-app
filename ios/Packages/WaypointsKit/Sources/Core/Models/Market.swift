import Foundation

// Section 5.5: market

/// `wanted` is something the poster is looking for; its `priceCents` is a budget (MKT-8).
public enum ListingKind: String, Sendable, Codable, Hashable, CaseIterable { case part, car, wanted }
/// Part categories (MKT-7), the `listing_category` enum.
public enum ListingCategory: String, Sendable, Codable, Hashable, CaseIterable {
    case wheelsTires = "wheels_tires", exhaust, intakeFuel = "intake_fuel", forcedInduction = "forced_induction", engine
    case drivetrain, suspension, brakes, exteriorAero = "exterior_aero", interior, lighting
    case electronicsTuning = "electronics_tuning", tools, apparel, other
}
public enum ListingCondition: String, Sendable, Codable, Hashable, CaseIterable { case new, used, forParts = "for_parts" }
public enum ListingStatus: String, Sendable, Codable, Hashable, CaseIterable { case active, pending, sold, removed }

public struct Fitment: Hashable, Sendable, Codable {
    public var make: String
    public var model: String?
    public var yearFrom: Int?
    public var yearTo: Int?
    public init(make: String, model: String? = nil, yearFrom: Int? = nil, yearTo: Int? = nil) {
        self.make = make; self.model = model; self.yearFrom = yearFrom; self.yearTo = yearTo
    }
}

public struct Listing: Identifiable, Hashable, Sendable, Codable {
    public let id: ListingID
    public let sellerID: UserID
    public var kind: ListingKind
    public var title: String                  // ≤70
    public var priceCents: Int
    public var condition: ListingCondition
    public var description: String            // ≤1500
    public var fits: Fitment?
    public var carID: CarID?
    public var region: String
    public var status: ListingStatus
    public var photos: [ListingPhoto]
    public var savedByMe: Bool
    public var createdAt: Date
    public var category: ListingCategory?
    /// Last time the seller touched it (MKT-9); nil means unknown and never expires.
    public var updatedAt: Date?
    public init(id: ListingID = ListingID(), sellerID: UserID, kind: ListingKind, title: String, priceCents: Int,
                condition: ListingCondition, description: String = "", fits: Fitment? = nil, carID: CarID? = nil,
                region: String, status: ListingStatus = .active, photos: [ListingPhoto] = [], savedByMe: Bool = false,
                createdAt: Date = .now, category: ListingCategory? = nil, updatedAt: Date? = nil) {
        self.id = id; self.sellerID = sellerID; self.kind = kind; self.title = title; self.priceCents = priceCents
        self.condition = condition; self.description = description; self.fits = fits; self.carID = carID
        self.region = region; self.status = status; self.photos = photos; self.savedByMe = savedByMe
        self.createdAt = createdAt; self.category = category; self.updatedAt = updatedAt
    }

    /// MKT-9: an active listing untouched this long leaves browse and reads "Expired" to its seller.
    public static let expiresAfter: TimeInterval = 90 * 24 * 3600
    public func isExpired(at date: Date = .now) -> Bool {
        guard status == .active, let u = updatedAt else { return false }
        return date.timeIntervalSince(u) > Self.expiresAfter
    }
}

public struct ListingDraft: Hashable, Sendable, Codable {
    public var kind: ListingKind
    public var title: String
    public var priceCents: Int
    public var condition: ListingCondition
    public var description: String
    public var fits: Fitment?
    public var carID: CarID?
    public var region: String
    public var photoPaths: [String]
    public var category: ListingCategory?
    /// Where it is, for the distance filter (MKT-1). The repository stores it rounded to 0.1 degree.
    public var near: Coordinate?
    public init(kind: ListingKind, title: String, priceCents: Int, condition: ListingCondition, description: String,
                fits: Fitment? = nil, carID: CarID? = nil, region: String, photoPaths: [String] = [],
                category: ListingCategory? = nil, near: Coordinate? = nil) {
        self.kind = kind; self.title = title; self.priceCents = priceCents; self.condition = condition
        self.description = description; self.fits = fits; self.carID = carID; self.region = region
        self.photoPaths = photoPaths; self.category = category; self.near = near
    }
}

public struct ListingPhoto: Identifiable, Hashable, Sendable, Codable {
    public let id: ListingPhotoID
    public var path: String
    public var sort: Int
    public init(id: ListingPhotoID = ListingPhotoID(), path: String, sort: Int = 0) {
        self.id = id; self.path = path; self.sort = sort
    }
}

public struct ListingFilter: Hashable, Sendable, Codable {
    public var kind: ListingKind?
    public var query: String?
    public var fits: Fitment?
    public var near: Coordinate?
    public var category: ListingCategory?
    /// With `near`, keeps listings whose coarse cell (0.1 degree) falls within about this distance (MKT-1).
    public var radiusMeters: Int?
    public init(kind: ListingKind? = nil, query: String? = nil, fits: Fitment? = nil, near: Coordinate? = nil,
                category: ListingCategory? = nil, radiusMeters: Int? = nil) {
        self.kind = kind; self.query = query; self.fits = fits; self.near = near; self.category = category
        self.radiusMeters = radiusMeters
    }
}
