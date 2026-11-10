import Foundation

/// A typed UUID identifier. Encodes as a bare UUID string so it maps to a `uuid` column.
public protocol UUIDIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    var raw: UUID { get }
    init(raw: UUID)
}

public extension UUIDIdentifier {
    init() { self.init(raw: UUID()) }
    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(raw: uuid)
    }
    init(from decoder: any Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(UUID.self))
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
    var description: String { raw.uuidString.lowercased() }
}

public struct UserID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
/// Compact numeric id used on the wire (`profiles.uid`).
public typealias RealtimeUID = UInt64

public struct CarID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct CarPhotoID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct BuildEntryID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ReportID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct MeetID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct VenueNoteID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct RoadID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct SpotID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct TeamID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct TeamRoleID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ChannelID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ThreadID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct PostID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct CommentID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ListingID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ListingPhotoID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ContentReportID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct RaceResultID: UUIDIdentifier { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

/// `messages.id` is a `bigint identity`, so ordering by id is ordering by insert.
public struct MessageID: Hashable, Sendable, Codable, Comparable {
    public let raw: Int64
    public init(raw: Int64) { self.raw = raw }
    public init(from decoder: any Decoder) throws { raw = try decoder.singleValueContainer().decode(Int64.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
    public static func < (lhs: MessageID, rhs: MessageID) -> Bool { lhs.raw < rhs.raw }
}

/// Convoys live in the gateway; their ids are strings on the wire (`JoinConvoy.convoy_id`).
public struct ConvoyID: Hashable, Sendable, Codable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public init(from decoder: any Decoder) throws { raw = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(raw) }
}
