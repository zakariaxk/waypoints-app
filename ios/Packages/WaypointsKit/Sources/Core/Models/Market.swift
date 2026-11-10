import Foundation

// Section 5.5: market

public enum ListingKind: String, Sendable, Codable, Hashable, CaseIterable { case part, car }
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
    public init(id: ListingID = ListingID(), sellerID: UserID, kind: ListingKind, title: String, priceCents: Int,
                condition: ListingCondition, description: String = "", fits: Fitment? = nil, carID: CarID? = nil,
                region: String, status: ListingStatus = .active, photos: [ListingPhoto] = [], savedByMe: Bool = false,
                createdAt: Date = .now) {
        self.id = id; self.sellerID = sellerID; self.kind = kind; self.title = title; self.priceCents = priceCents
        self.condition = condition; self.description = description; self.fits = fits; self.carID = carID
        self.region = region; self.status = status; self.photos = photos; self.savedByMe = savedByMe
        self.createdAt = createdAt
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
    public init(kind: ListingKind, title: String, priceCents: Int, condition: ListingCondition, description: String,
                fits: Fitment? = nil, carID: CarID? = nil, region: String, photoPaths: [String] = []) {
        self.kind = kind; self.title = title; self.priceCents = priceCents; self.condition = condition
        self.description = description; self.fits = fits; self.carID = carID; self.region = region
        self.photoPaths = photoPaths
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
    public init(kind: ListingKind? = nil, query: String? = nil, fits: Fitment? = nil, near: Coordinate? = nil) {
        self.kind = kind; self.query = query; self.fits = fits; self.near = near
    }
}
