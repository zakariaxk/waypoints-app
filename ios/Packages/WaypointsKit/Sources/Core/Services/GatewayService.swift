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

    // Help requests (PRD HELP). One active per person; a second post throws `.conflict`.
    func helpRequests(in region: MapRegion) async throws -> [HelpRequest]
    func helpRequest(_ id: HelpRequestID) async throws -> HelpRequest
    @discardableResult func postHelp(_ draft: HelpDraft) async throws -> HelpRequest
    /// "On my way": the requester is told who is coming.
    @discardableResult func respondToHelp(_ id: HelpRequestID) async throws -> HelpRequest
    /// "I'm good" (requester only).
    func endHelp(_ id: HelpRequestID) async throws
    /// Another 60 minutes from now (requester only).
    @discardableResult func extendHelp(_ id: HelpRequestID) async throws -> HelpRequest

    // Meets (3 per user per day)
    @discardableResult func createMeet(_ draft: MeetDraft) async throws -> Meet
    @discardableResult func updateMeet(_ id: MeetID, _ draft: MeetDraft) async throws -> Meet
    func cancelMeet(_ id: MeetID) async throws
    /// Cancels this occurrence and every later one of its series, ending the series (MEET-12).
    func cancelMeetAndFollowing(_ id: MeetID) async throws

    // Convoys
    /// `routePolyline`: Google encoded polyline (precision 5) the convoy drives, e.g. a saved road (MEET-13).
    func createConvoy(name: String, destination: ConvoyDestination?, routePolyline: String?) async throws -> ConvoyInvite
    func joinConvoy(code: String) async throws -> ConvoyState
    func setConvoyDestination(_ id: ConvoyID, _ destination: ConvoyDestination) async throws
    func setConvoyRegroup(_ id: ConvoyID, at coordinate: Coordinate) async throws
    func endConvoy(_ id: ConvoyID) async throws
    /// Pushes the join code to these users (M9 "Invite friends").
    func inviteToConvoy(_ id: ConvoyID, users: [UserID]) async throws

    // Voice
    func voiceToken(for channel: ChannelID) async throws -> VoiceCredentials
    /// Room `cv_<convoy_id>`, current members only (CNV-11).
    func voiceToken(forConvoy convoy: ConvoyID) async throws -> VoiceCredentials

    // Share ETA (NAV-15). One notice to chosen friends: destination name and arrival time, no
    // position. With `meet`, marks your Going RSVP "on the way". Recipients may be empty then.
    @discardableResult func shareETA(_ share: ETAShare) async throws -> ETAShareResult
}

/// `POST /v1/eta` (NAV-15).
public struct ETAShare: Hashable, Sendable {
    public var recipients: [UserID]
    public var destination: String
    public var arriveAt: Date
    public var meet: MeetID?
    public init(recipients: [UserID], destination: String, arriveAt: Date, meet: MeetID? = nil) {
        self.recipients = recipients; self.destination = destination; self.arriveAt = arriveAt; self.meet = meet
    }
}

public struct ETAShareResult: Hashable, Sendable, Codable {
    /// Friends the notice went to (non-friends and blocked pairs are dropped).
    public var sent: Int
    public var onTheWay: Bool
    public init(sent: Int, onTheWay: Bool) { self.sent = sent; self.onTheWay = onTheWay }
}

public extension GatewayService {
    func createConvoy(name: String, destination: ConvoyDestination?) async throws -> ConvoyInvite {
        try await createConvoy(name: name, destination: destination, routePolyline: nil)
    }
}
