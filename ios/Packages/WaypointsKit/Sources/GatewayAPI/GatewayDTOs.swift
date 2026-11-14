import Core
import Foundation

// JSON bodies for the gateway API (plan section 6). Property names are camelCase here and
// snake_case on the wire through `GatewayClient`'s key strategies.

/// `PUT /v1/privacy`. `ghost_until` is always present, `null` when ghost is off, so the gateway
/// can tell "turned off" from "not sent".
struct PrivacyBody: Encodable, Sendable {
    var friendsLevel: PrivacyLevel
    var teamLevel: PrivacyLevel
    var nearbyLevel: PrivacyLevel
    var ghostUntil: Date?
    var notifyMeetsNearby: Bool
    var notifyRadiusKm: Int

    init(_ s: PrivacySettings) {
        friendsLevel = s.friendsLevel; teamLevel = s.teamLevel
        nearbyLevel = s.nearbyLevel == .precise ? .approx : s.nearbyLevel
        ghostUntil = s.ghostUntil; notifyMeetsNearby = s.notifyMeetsNearby; notifyRadiusKm = s.notifyRadiusKm
    }

    enum CodingKeys: String, CodingKey {
        case friendsLevel, teamLevel, nearbyLevel, ghostUntil, notifyMeetsNearby, notifyRadiusKm
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(friendsLevel, forKey: .friendsLevel)
        try c.encode(teamLevel, forKey: .teamLevel)
        try c.encode(nearbyLevel, forKey: .nearbyLevel)
        try c.encode(ghostUntil, forKey: .ghostUntil)
        try c.encode(notifyMeetsNearby, forKey: .notifyMeetsNearby)
        try c.encode(notifyRadiusKm, forKey: .notifyRadiusKm)
    }
}

struct ReportBody: Encodable, Sendable {
    var kind: ReportKind
    var lat: Double
    var lng: Double
    var note: String?
}

struct VoteBody: Encodable, Sendable { var stillThere: Bool }
/// `DELETE /v1/meets/{id}` with `scope: "following"` also cancels later occurrences (MEET-12).
struct CancelMeetBody: Encodable, Sendable { var scope: String }
struct InviteBody: Encodable, Sendable { var userIds: [UserID] }
/// `POST /v1/eta` (NAV-15). `meet_id` is sent as null when absent.
struct ETABody: Encodable, Sendable {
    var recipients: [UserID]; var destination: String; var arriveAt: Date; var meetId: MeetID?
    enum CodingKeys: String, CodingKey { case recipients, destination, arriveAt, meetId }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recipients, forKey: .recipients)
        try c.encode(destination, forKey: .destination)
        try c.encode(arriveAt, forKey: .arriveAt)
        try c.encodeIfPresent(meetId, forKey: .meetId)
    }
}
struct JoinConvoyBody: Encodable, Sendable { var joinCode: String }
struct VoiceBody: Encodable, Sendable { var channelId: ChannelID }
struct ConvoyVoiceBody: Encodable, Sendable { var convoyId: ConvoyID }
struct PointDTO: Codable, Sendable { var lat: Double; var lng: Double }

struct PlaceDTO: Codable, Sendable {
    var lat: Double
    var lng: Double
    var name: String
    init(_ d: ConvoyDestination) { lat = d.coordinate.latitude; lng = d.coordinate.longitude; name = d.name }
    var model: ConvoyDestination { ConvoyDestination(coordinate: Coordinate(latitude: lat, longitude: lng), name: name) }
}

struct CreateConvoyBody: Encodable, Sendable {
    var name: String
    var destination: PlaceDTO?
}

struct MeetBody: Encodable, Sendable {
    var title: String
    var kind: MeetKind
    var lat: Double
    var lng: Double
    var placeName: String
    var startsAt: Date
    var endsAt: Date
    var details: String
    var visibility: MeetVisibility
    var teamId: TeamID?
    var recurrence: MeetRecurrence?
    /// The zone a series repeats in, so "Saturdays 8 AM" holds across daylight saving.
    var timeZone: String
    var destination: PlaceDTO?

    init(_ d: MeetDraft) {
        title = d.title; kind = d.kind; lat = d.coordinate.latitude; lng = d.coordinate.longitude
        placeName = d.placeName; startsAt = d.startsAt; endsAt = d.endsAt; details = d.details
        visibility = d.visibility; teamId = d.teamID
        recurrence = d.recurrence; timeZone = TimeZone.current.identifier; destination = d.destination.map(PlaceDTO.init)
    }
}

/// A `reports` row as the gateway returns it.
struct ReportDTO: Decodable, Sendable {
    var id: ReportID
    var authorId: UserID
    var kind: ReportKind
    var lat: Double
    var lng: Double
    var note: String?
    var confirmations: Int?
    var expiresAt: Date?
    var permanent: Bool?
    var createdAt: Date?

    var model: Report {
        Report(id: id, authorID: authorId, kind: kind, coordinate: Coordinate(latitude: lat, longitude: lng), note: note,
               confirmations: confirmations ?? 1, expiresAt: expiresAt, permanent: permanent ?? (expiresAt == nil),
               createdAt: createdAt ?? .now)
    }
}

/// A `meets` row as the gateway returns it.
struct MeetDTO: Decodable, Sendable {
    var id: MeetID
    var hostId: UserID
    var title: String
    var kind: MeetKind
    var lat: Double
    var lng: Double
    var placeName: String
    var startsAt: Date
    var endsAt: Date
    var details: String?
    var visibility: MeetVisibility
    var teamId: TeamID?
    var cancelledAt: Date?
    var createdAt: Date?
    var recurrence: MeetRecurrence?
    var seriesId: UUID?
    var destination: PlaceDTO?

    var model: Meet {
        Meet(id: id, hostID: hostId, title: title, kind: kind, coordinate: Coordinate(latitude: lat, longitude: lng),
             placeName: placeName, startsAt: startsAt, endsAt: endsAt, details: details ?? "", visibility: visibility,
             teamID: teamId, cancelledAt: cancelledAt, createdAt: createdAt ?? .now,
             recurrence: recurrence, seriesID: seriesId, destination: destination?.model)
    }
}

/// Convoy state from `POST /v1/convoys/join`; mirrors the wire `ConvoyState`.
struct ConvoyDTO: Decodable, Sendable {
    struct Regroup: Decodable, Sendable { var lat: Double; var lng: Double; var setAt: Date }
    var id: ConvoyID
    var leaderUid: RealtimeUID
    var memberUids: [RealtimeUID]
    var destination: PlaceDTO?
    /// Encoded polyline text.
    var routePolyline: String?
    var regroup: Regroup?
    var ended: Bool?

    var model: ConvoyState {
        ConvoyState(id: id, leaderUID: leaderUid, memberUIDs: memberUids, destination: destination?.model,
                    routePolyline: Data((routePolyline ?? "").utf8),
                    regroup: regroup.map { ConvoyRegroup(coordinate: Coordinate(latitude: $0.lat, longitude: $0.lng),
                                                         setAt: $0.setAt) },
                    ended: ended ?? false)
    }
}

// MARK: Help requests (PRD HELP)

struct HelpBody: Encodable, Sendable {
    var kind: HelpKind
    var lat: Double
    var lng: Double
    var note: String?
    var showNearby: Bool
    init(_ d: HelpDraft) {
        kind = d.kind; lat = d.coordinate.latitude; lng = d.coordinate.longitude; note = d.note; showNearby = d.showNearby
    }
}

/// A help request as the gateway returns it for this viewer.
struct HelpDTO: Decodable, Sendable {
    struct Responder: Decodable, Sendable { var userId: UserID; var displayName: String }
    var id: HelpRequestID
    var requesterId: UserID?
    var kind: HelpKind
    var lat: Double
    var lng: Double
    var note: String?
    var showNearby: Bool?
    var displayName: String?
    var carLabel: String?
    var expiresAt: Date
    var createdAt: Date?
    var mine: Bool?
    var coming: Bool?
    var responders: [Responder]?
    var responderCount: Int?

    var model: HelpRequest {
        HelpRequest(id: id, requesterID: requesterId, kind: kind, coordinate: Coordinate(latitude: lat, longitude: lng),
                    note: note, showNearby: showNearby ?? false, displayName: displayName, carLabel: carLabel,
                    expiresAt: expiresAt, createdAt: createdAt ?? .now, isMine: mine ?? false, isComing: coming ?? false,
                    responders: (responders ?? []).map { HelpResponder(userID: $0.userId, displayName: $0.displayName) },
                    responderCount: responderCount ?? 0)
    }
}
