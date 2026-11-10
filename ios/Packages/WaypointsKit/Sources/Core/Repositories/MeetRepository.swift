import Foundation

/// `meets` (read), `meet_rsvps`, `venue_notes`. Section 5.3. Creating, editing, and cancelling
/// meets goes through `GatewayService` so it can fan out and push.
public protocol MeetRepository: Sendable {
    /// `meets_in_bbox`: only meets ending in the future.
    func meets(in region: MapRegion) async throws -> [Meet]
    func meet(_ id: MeetID) async throws -> Meet
    func upcomingMeets(for user: UserID) async throws -> [Meet]
    func rsvps(for meet: MeetID) async throws -> [MeetRSVP]
    func myRSVP(for meet: MeetID) async throws -> MeetRSVP?
    func setRSVP(_ status: RSVPStatus, for meet: MeetID, car: CarID?) async throws
    func clearRSVP(for meet: MeetID) async throws
    /// `venue_notes_near`.
    func venueNotes(near coordinate: Coordinate, meters: Int) async throws -> [VenueNote]
    @discardableResult func addVenueNote(_ note: VenueNote) async throws -> VenueNote
}
