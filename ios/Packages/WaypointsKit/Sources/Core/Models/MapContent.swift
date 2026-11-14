import Foundation

// Section 5.3

public enum ReportKind: String, Sendable, Codable, Hashable, CaseIterable {
    case speedBump = "speed_bump", steepEntrance = "steep_entrance", pothole, roughRoad = "rough_road"
    case police, hazard, closure, fuelE85 = "fuel_e85"
    case speedCamera = "speed_camera", redLightCamera = "red_light_camera"

    /// Lifetimes from section 5.3. `nil` means permanent.
    public var lifetime: TimeInterval? {
        switch self {
        case .police: 45 * 60
        case .hazard: 2 * 3600
        case .closure: 24 * 3600
        case .pothole, .roughRoad: 90 * 86_400
        case .speedBump, .steepEntrance, .fuelE85, .speedCamera, .redLightCamera: nil
        }
    }
    /// Kinds that matter for a lowered car's route (section 2.4, low-car routing).
    public var affectsClearance: Bool { [.speedBump, .steepEntrance, .pothole, .roughRoad].contains(self) }
}

public struct Report: Identifiable, Hashable, Sendable, Codable {
    public let id: ReportID
    public let authorID: UserID
    public var kind: ReportKind
    public var coordinate: Coordinate
    public var note: String?                  // ≤120
    public var confirmations: Int
    public var expiresAt: Date?
    public var permanent: Bool
    public var createdAt: Date
    public init(id: ReportID = ReportID(), authorID: UserID, kind: ReportKind, coordinate: Coordinate, note: String? = nil,
                confirmations: Int = 1, expiresAt: Date? = nil, permanent: Bool = false, createdAt: Date = .now) {
        self.id = id; self.authorID = authorID; self.kind = kind; self.coordinate = coordinate; self.note = note
        self.confirmations = confirmations; self.expiresAt = expiresAt; self.permanent = permanent; self.createdAt = createdAt
    }
}

public enum MeetKind: String, Sendable, Codable, Hashable, CaseIterable { case meet, cruise, hangout, trackDay = "track_day", show }
public enum MeetVisibility: String, Sendable, Codable, Hashable, CaseIterable { case `public`, friends, team }
/// MEET-12: monthly repeats on the same weekday of the same week.
public enum MeetRecurrence: String, Sendable, Codable, Hashable, CaseIterable { case weekly, biweekly, monthly }

public struct Meet: Identifiable, Hashable, Sendable, Codable {
    public let id: MeetID
    public let hostID: UserID
    public var title: String                  // ≤50
    public var kind: MeetKind
    public var coordinate: Coordinate
    public var placeName: String
    public var startsAt: Date
    public var endsAt: Date
    public var details: String                // ≤500
    public var visibility: MeetVisibility
    public var teamID: TeamID?
    public var cancelledAt: Date?
    public var createdAt: Date
    /// How the series repeats (MEET-12); nil for a one-off or a series that was ended.
    public var recurrence: MeetRecurrence?
    /// Shared by every occurrence of a recurring meet.
    public var seriesID: UUID?
    /// Where a cruise rolls out to (MEET-13).
    public var destination: ConvoyDestination?
    /// The saved road a cruise drives (MEET-13); Roll out starts the convoy on it.
    public var roadID: RoadID?
    /// People's choice winner, set when a meet or show with votes ends (MEET-14).
    public var winnerCarID: CarID?
    public init(id: MeetID = MeetID(), hostID: UserID, title: String, kind: MeetKind, coordinate: Coordinate,
                placeName: String, startsAt: Date, endsAt: Date, details: String = "",
                visibility: MeetVisibility = .public, teamID: TeamID? = nil, cancelledAt: Date? = nil,
                createdAt: Date = .now, recurrence: MeetRecurrence? = nil, seriesID: UUID? = nil,
                destination: ConvoyDestination? = nil, roadID: RoadID? = nil, winnerCarID: CarID? = nil) {
        self.id = id; self.hostID = hostID; self.title = title; self.kind = kind; self.coordinate = coordinate
        self.placeName = placeName; self.startsAt = startsAt; self.endsAt = endsAt; self.details = details
        self.visibility = visibility; self.teamID = teamID; self.cancelledAt = cancelledAt; self.createdAt = createdAt
        self.recurrence = recurrence; self.seriesID = seriesID; self.destination = destination
        self.roadID = roadID; self.winnerCarID = winnerCarID
    }
    public func isHappening(at date: Date = .now) -> Bool { cancelledAt == nil && startsAt <= date && date < endsAt }
}

/// Body of `POST /v1/meets` and `PATCH /v1/meets/{id}`.
public struct MeetDraft: Hashable, Sendable, Codable {
    public var title: String
    public var kind: MeetKind
    public var coordinate: Coordinate
    public var placeName: String
    public var startsAt: Date
    public var endsAt: Date
    public var details: String
    public var visibility: MeetVisibility
    public var teamID: TeamID?
    public var recurrence: MeetRecurrence?
    public var destination: ConvoyDestination?
    public var roadID: RoadID?
    public init(title: String, kind: MeetKind, coordinate: Coordinate, placeName: String, startsAt: Date,
                endsAt: Date, details: String = "", visibility: MeetVisibility = .public, teamID: TeamID? = nil,
                recurrence: MeetRecurrence? = nil, destination: ConvoyDestination? = nil, roadID: RoadID? = nil) {
        self.title = title; self.kind = kind; self.coordinate = coordinate; self.placeName = placeName
        self.startsAt = startsAt; self.endsAt = endsAt; self.details = details; self.visibility = visibility
        self.teamID = teamID; self.recurrence = recurrence; self.destination = destination; self.roadID = roadID
    }
}

public enum RSVPStatus: String, Sendable, Codable, Hashable { case going, maybe }

public struct MeetRSVP: Hashable, Sendable, Codable {
    public let meetID: MeetID
    public let userID: UserID
    public var status: RSVPStatus
    public var carID: CarID?
    /// Set while this person, Going, is navigating here (NAV-15). No position, only the flag.
    public var onTheWayUntil: Date?
    public init(meetID: MeetID, userID: UserID, status: RSVPStatus, carID: CarID? = nil, onTheWayUntil: Date? = nil) {
        self.meetID = meetID; self.userID = userID; self.status = status; self.carID = carID
        self.onTheWayUntil = onTheWayUntil
    }
    /// "On the way" shows only while the flag is in the future and the RSVP is Going.
    public func isOnTheWay(at now: Date = .now) -> Bool {
        status == .going && (onTheWayUntil.map { $0 > now } ?? false)
    }
}

public enum EntranceGrade: String, Sendable, Codable, Hashable, CaseIterable { case flat, moderate, steep }
public enum LotSize: String, Sendable, Codable, Hashable, CaseIterable { case small, medium, large }

public struct VenueNote: Identifiable, Hashable, Sendable, Codable {
    public let id: VenueNoteID
    public let authorID: UserID
    public var coordinate: Coordinate
    public var entrance: EntranceGrade
    public var lotSize: LotSize
    public var lit: Bool
    public var note: String?                  // ≤120
    public var createdAt: Date
    public init(id: VenueNoteID = VenueNoteID(), authorID: UserID, coordinate: Coordinate, entrance: EntranceGrade,
                lotSize: LotSize, lit: Bool, note: String? = nil, createdAt: Date = .now) {
        self.id = id; self.authorID = authorID; self.coordinate = coordinate; self.entrance = entrance
        self.lotSize = lotSize; self.lit = lit; self.note = note; self.createdAt = createdAt
    }
}

public struct Road: Identifiable, Hashable, Sendable, Codable {
    public let id: RoadID
    public let authorID: UserID
    public var name: String                   // ≤50
    public var path: [Coordinate]
    public var lengthMeters: Int
    public var ratings: RoadRatingSummary
    public var createdAt: Date
    public init(id: RoadID = RoadID(), authorID: UserID, name: String, path: [Coordinate], lengthMeters: Int,
                ratings: RoadRatingSummary = .init(), createdAt: Date = .now) {
        self.id = id; self.authorID = authorID; self.name = name; self.path = path
        self.lengthMeters = lengthMeters; self.ratings = ratings; self.createdAt = createdAt
    }
}

public struct RoadRating: Hashable, Sendable, Codable {
    public var surface: Int                   // 1–5
    public var scenery: Int
    public var traffic: Int
    public init(surface: Int, scenery: Int, traffic: Int) {
        self.surface = surface; self.scenery = scenery; self.traffic = traffic
    }
}

public struct RoadRatingSummary: Hashable, Sendable, Codable {
    public var surface: Double
    public var scenery: Double
    public var traffic: Double
    public var count: Int
    public init(surface: Double = 0, scenery: Double = 0, traffic: Double = 0, count: Int = 0) {
        self.surface = surface; self.scenery = scenery; self.traffic = traffic; self.count = count
    }
}

public struct Spot: Identifiable, Hashable, Sendable, Codable {
    public let id: SpotID
    public let spotterID: UserID
    public var catalogModelID: Int64
    public var year: Int?
    public var make: String
    public var model: String
    public var photoPath: String
    public var city: String                   // city level only, never precise coordinates
    public var createdAt: Date
    public init(id: SpotID = SpotID(), spotterID: UserID, catalogModelID: Int64, year: Int? = nil, make: String,
                model: String, photoPath: String, city: String, createdAt: Date = .now) {
        self.id = id; self.spotterID = spotterID; self.catalogModelID = catalogModelID; self.year = year
        self.make = make; self.model = model; self.photoPath = photoPath; self.city = city; self.createdAt = createdAt
    }
}

// Help requests (PRD HELP-1..7, migration W7-4). Served only by the gateway.

public struct HelpRequestID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

public enum HelpKind: String, Sendable, Codable, Hashable, CaseIterable {
    case flatTire = "flat_tire", jumpStart = "jump_start", outOfFuel = "out_of_fuel", stuck, other
}

public struct HelpResponder: Hashable, Sendable, Codable {
    public let userID: UserID
    public var displayName: String
    public init(userID: UserID, displayName: String) { self.userID = userID; self.displayName = displayName }
}

/// An active help request as one viewer sees it. `requesterID`, `displayName`, and `carLabel`
/// are `nil` in the anonymous nearby form ("A driver needs a hand").
public struct HelpRequest: Identifiable, Hashable, Sendable, Codable {
    public let id: HelpRequestID
    public var requesterID: UserID?
    public var kind: HelpKind
    public var coordinate: Coordinate
    public var note: String?                  // ≤120
    public var showNearby: Bool
    public var displayName: String?
    public var carLabel: String?
    public var expiresAt: Date
    public var createdAt: Date
    /// The viewer posted it.
    public var isMine: Bool
    /// The viewer tapped "On my way".
    public var isComing: Bool
    /// Who is coming; filled only for the requester.
    public var responders: [HelpResponder]
    public var responderCount: Int
    public init(id: HelpRequestID = HelpRequestID(), requesterID: UserID?, kind: HelpKind, coordinate: Coordinate,
                note: String? = nil, showNearby: Bool = false, displayName: String? = nil, carLabel: String? = nil,
                expiresAt: Date = .now.addingTimeInterval(HelpRequest.lifetime), createdAt: Date = .now,
                isMine: Bool = false, isComing: Bool = false, responders: [HelpResponder] = [], responderCount: Int = 0) {
        self.id = id; self.requesterID = requesterID; self.kind = kind; self.coordinate = coordinate; self.note = note
        self.showNearby = showNearby; self.displayName = displayName; self.carLabel = carLabel
        self.expiresAt = expiresAt; self.createdAt = createdAt; self.isMine = isMine; self.isComing = isComing
        self.responders = responders; self.responderCount = responderCount
    }
    /// Without an extension a request ends after 60 minutes (HELP-6).
    public static let lifetime: TimeInterval = 60 * 60
    /// Friends and teammates this close are notified (HELP-4).
    public static let notifyRadiusMeters = 25_000
}

/// Body of `POST /v1/help`.
public struct HelpDraft: Hashable, Sendable, Codable {
    public var kind: HelpKind
    public var coordinate: Coordinate
    public var note: String?
    public var showNearby: Bool
    public init(kind: HelpKind, coordinate: Coordinate, note: String? = nil, showNearby: Bool = false) {
        self.kind = kind; self.coordinate = coordinate; self.note = note; self.showNearby = showNearby
    }
}
