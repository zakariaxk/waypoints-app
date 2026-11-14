import Core
import Foundation

/// `GatewayService` against the Go gateway. Request and response shapes follow plan section 6;
/// coordinates are plain `lat`/`lng` degrees in JSON.
public struct LiveGatewayService: GatewayService {
    private let client: GatewayClient

    public init(baseURL: URL, auth: any AuthService) {
        client = GatewayClient(baseURL: baseURL, auth: auth)
    }

    // MARK: Privacy

    public func updatePrivacy(_ settings: PrivacySettings) async throws {
        try await client.send("PUT", "v1/privacy", body: PrivacyBody(settings))
    }

    // MARK: Reports

    public func postReport(kind: ReportKind, at coordinate: Coordinate, note: String?) async throws -> Report {
        try await client.send("POST", "v1/reports",
                              body: ReportBody(kind: kind, lat: coordinate.latitude, lng: coordinate.longitude, note: note),
                              as: ReportDTO.self).model
    }

    public func voteReport(_ id: ReportID, stillThere: Bool) async throws {
        try await client.send("POST", "v1/reports/\(id)/vote", body: VoteBody(stillThere: stillThere))
    }

    public func undoReport(_ id: ReportID) async throws {
        try await client.send("DELETE", "v1/reports/\(id)")
    }

    // MARK: Meets

    public func createMeet(_ draft: MeetDraft) async throws -> Meet {
        try await client.send("POST", "v1/meets", body: MeetBody(draft), as: MeetDTO.self).model
    }

    public func updateMeet(_ id: MeetID, _ draft: MeetDraft) async throws -> Meet {
        try await client.send("PATCH", "v1/meets/\(id)", body: MeetBody(draft), as: MeetDTO.self).model
    }

    public func cancelMeet(_ id: MeetID) async throws {
        try await client.send("DELETE", "v1/meets/\(id)")
    }

    // MARK: Convoys

    public func createConvoy(name: String, destination: ConvoyDestination?) async throws -> ConvoyInvite {
        try await client.send("POST", "v1/convoys",
                              body: CreateConvoyBody(name: name, destination: destination.map(PlaceDTO.init)),
                              as: ConvoyInvite.self)
    }

    public func joinConvoy(code: String) async throws -> ConvoyState {
        try await client.send("POST", "v1/convoys/join", body: JoinConvoyBody(joinCode: code), as: ConvoyDTO.self).model
    }

    public func setConvoyDestination(_ id: ConvoyID, _ destination: ConvoyDestination) async throws {
        try await client.send("PUT", "v1/convoys/\(id.raw)/destination", body: PlaceDTO(destination))
    }

    public func setConvoyRegroup(_ id: ConvoyID, at coordinate: Coordinate) async throws {
        try await client.send("PUT", "v1/convoys/\(id.raw)/regroup",
                              body: PointDTO(lat: coordinate.latitude, lng: coordinate.longitude))
    }

    public func inviteToConvoy(_ id: ConvoyID, users: [UserID]) async throws {
        try await client.send("POST", "v1/convoys/\(id.raw)/invite", body: InviteBody(userIds: users))
    }

    public func endConvoy(_ id: ConvoyID) async throws {
        try await client.send("DELETE", "v1/convoys/\(id.raw)")
    }

    // MARK: Voice

    public func voiceToken(for channel: ChannelID) async throws -> VoiceCredentials {
        try await client.send("POST", "v1/voice/token", body: VoiceBody(channelId: channel), as: VoiceCredentials.self)
    }

    public func voiceToken(forConvoy convoy: ConvoyID) async throws -> VoiceCredentials {
        try await client.send("POST", "v1/voice/token", body: ConvoyVoiceBody(convoyId: convoy), as: VoiceCredentials.self)
    }
}
