import Foundation

/// The Go gateway's HTTP JSON API (section 6), implemented by `GatewayAPI`.
public protocol GatewayService: Sendable {
    // Privacy
    func updatePrivacy(_ settings: PrivacySettings) async throws

    // Reports
    @discardableResult func postReport(kind: ReportKind, at coordinate: Coordinate, note: String?) async throws -> Report
    func voteReport(_ id: ReportID, stillThere: Bool) async throws
    /// The author's own report, within 5 minutes of posting (M5 "Undo").
    func undoReport(_ id: ReportID) async throws

    // Meets (3 per user per day)
    @discardableResult func createMeet(_ draft: MeetDraft) async throws -> Meet
    @discardableResult func updateMeet(_ id: MeetID, _ draft: MeetDraft) async throws -> Meet
    func cancelMeet(_ id: MeetID) async throws

    // Convoys
    func createConvoy(name: String, destination: ConvoyDestination?) async throws -> ConvoyInvite
    func joinConvoy(code: String) async throws -> ConvoyState
    func setConvoyDestination(_ id: ConvoyID, _ destination: ConvoyDestination) async throws
    func setConvoyRegroup(_ id: ConvoyID, at coordinate: Coordinate) async throws
    func endConvoy(_ id: ConvoyID) async throws
    /// Pushes the join code to these users (M9 "Invite friends").
    func inviteToConvoy(_ id: ConvoyID, users: [UserID]) async throws

    // Voice
    func voiceToken(for channel: ChannelID) async throws -> VoiceCredentials
}
