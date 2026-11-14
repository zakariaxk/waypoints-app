import Foundation

// Client-side mirror of the wire types in section 6. `RealtimeClient` converts.

public enum LocationTier: String, Sendable, Codable, Hashable { case precise, approximate }
public enum Relation: String, Sendable, Codable, Hashable { case friend, teammate, convoy, nearby }

public struct EntityInfo: Hashable, Sendable {
    public var relation: Relation
    public var markerIcon: String
    public var markerTrail: String?
    public var paintRGB: UInt32
    /// Empty for `.nearby`.
    public var displayName: String
    /// Empty for `.nearby`.
    public var carLabel: String
    public init(relation: Relation, markerIcon: String, markerTrail: String? = nil, paintRGB: UInt32,
                displayName: String, carLabel: String) {
        self.relation = relation; self.markerIcon = markerIcon; self.markerTrail = markerTrail
        self.paintRGB = paintRGB; self.displayName = displayName; self.carLabel = carLabel
    }
}

public struct EntityUpdate: Hashable, Sendable {
    public var uid: RealtimeUID
    public var coordinate: Coordinate
    /// Degrees 0–359, `nil` when unknown or approximate.
    public var heading: Double?
    public var tier: LocationTier
    /// Seconds since the publisher's fix, at flush time.
    public var age: TimeInterval
    /// Publisher's client clock; set only when the server runs with `-bench`.
    public var originMs: UInt64?
    /// Present on first appearance and when it changes.
    public var info: EntityInfo?
    public init(uid: RealtimeUID, coordinate: Coordinate, heading: Double?, tier: LocationTier, age: TimeInterval,
                originMs: UInt64? = nil, info: EntityInfo? = nil) {
        self.uid = uid; self.coordinate = coordinate; self.heading = heading; self.tier = tier; self.age = age
        self.originMs = originMs; self.info = info
    }
}

/// Low-zoom count of drivers in one H3 cell.
public struct CellAggregate: Hashable, Sendable {
    public var h3: UInt64
    public var count: Int
    public init(h3: UInt64, count: Int) { self.h3 = h3; self.count = count }
}

public struct MapEvent: Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable { case report, meet, help }
    public enum Op: String, Sendable, Hashable { case upsert, remove }
    public var kind: Kind
    public var id: String
    public var op: Op
    public var coordinate: Coordinate
    /// `ReportKind`, `MeetKind`, or `HelpKind` raw value.
    public var subtype: String
    public var title: String
    public init(kind: Kind, id: String, op: Op, coordinate: Coordinate, subtype: String, title: String) {
        self.kind = kind; self.id = id; self.op = op; self.coordinate = coordinate; self.subtype = subtype; self.title = title
    }
}

public struct ConvoyDestination: Hashable, Sendable, Codable {
    public var coordinate: Coordinate
    public var name: String
    public init(coordinate: Coordinate, name: String) { self.coordinate = coordinate; self.name = name }
}

public struct ConvoyRegroup: Hashable, Sendable {
    public var coordinate: Coordinate
    public var setAt: Date
    public init(coordinate: Coordinate, setAt: Date) { self.coordinate = coordinate; self.setAt = setAt }
}

public struct ConvoyState: Hashable, Sendable {
    public var id: ConvoyID
    public var leaderUID: RealtimeUID
    public var memberUIDs: [RealtimeUID]
    public var destination: ConvoyDestination?
    /// Google encoded polyline, precision 5.
    public var routePolyline: Data
    public var regroup: ConvoyRegroup?
    public var ended: Bool
    public init(id: ConvoyID, leaderUID: RealtimeUID, memberUIDs: [RealtimeUID], destination: ConvoyDestination? = nil,
                routePolyline: Data = Data(), regroup: ConvoyRegroup? = nil, ended: Bool = false) {
        self.id = id; self.leaderUID = leaderUID; self.memberUIDs = memberUIDs; self.destination = destination
        self.routePolyline = routePolyline; self.regroup = regroup; self.ended = ended
    }
}

/// Returned by `POST /v1/convoys`.
public struct ConvoyInvite: Hashable, Sendable, Codable {
    public var id: ConvoyID
    public var joinCode: String
    public init(id: ConvoyID, joinCode: String) { self.id = id; self.joinCode = joinCode }
}

/// Returned by `POST /v1/voice/token`.
public struct VoiceCredentials: Hashable, Sendable, Codable {
    public var url: URL
    public var token: String
    public init(url: URL, token: String) { self.url = url; self.token = token }
}

/// One participant of a team voice room, from `GET /v1/voice/occupants` (TEAM-4).
public struct VoiceOccupant: Hashable, Sendable, Codable, Identifiable {
    /// LiveKit identity: the user's id for team voice rooms.
    public var userID: String
    public var name: String
    public var id: String { userID }
    public init(userID: String, name: String) { self.userID = userID; self.name = name }
}

public struct LocationSample: Hashable, Sendable {
    public var coordinate: Coordinate
    /// Degrees 0–359, `nil` when unknown.
    public var heading: Double?
    /// Meters per second. Your own only; the gateway never fans it out.
    public var speed: Double
    public var horizontalAccuracy: Double
    public var timestamp: Date
    public var isStationary: Bool
    public init(coordinate: Coordinate, heading: Double?, speed: Double, horizontalAccuracy: Double,
                timestamp: Date = .now, isStationary: Bool = false) {
        self.coordinate = coordinate; self.heading = heading; self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy; self.timestamp = timestamp; self.isStationary = isStationary
    }
}

public enum LocationAuthorization: Sendable, Hashable {
    case notDetermined, denied, restricted, whenInUse, always
    public var allowsUse: Bool { self == .whenInUse || self == .always }
}
