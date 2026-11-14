import Foundation

extension PreviewStore: ReportRepository {
    func liveReports(at date: Date = .now) -> [Report] {
        reports.values.filter { ($0.permanent || ($0.expiresAt ?? .distantFuture) > date) && visible($0.authorID) }
    }
    public func reports(in region: MapRegion) async throws -> [Report] {
        liveReports().filter { region.contains($0.coordinate) }
    }
    public func report(_ id: ReportID) async throws -> Report {
        guard let report = reports[id] else { throw WaypointsError.notFound }
        return report
    }
    public func hazards(along path: [Coordinate], bufferMeters: Int) async throws -> [Report] {
        liveReports().filter { report in path.contains { $0.distance(to: report.coordinate) <= Double(bufferMeters) } }
    }
    public func myVote(on report: ReportID) async throws -> Bool? { reportVotes[Pair(report.raw, try me().raw)] }
}

extension PreviewStore: MeetRepository {
    func canSee(_ meet: Meet) -> Bool {
        guard visible(meet.hostID), meet.cancelledAt == nil else { return false }
        guard let me = session?.userID else { return meet.visibility == .public }
        switch meet.visibility {
        case .public: return true
        case .friends: return meet.hostID == me || friendList().contains { $0.id == meet.hostID }
        case .team: return meet.teamID.map { team in members.contains { $0.teamID == team && $0.userID == me } } ?? false
        }
    }
    public func meets(in region: MapRegion) async throws -> [Meet] {
        meets.values.filter { canSee($0) && $0.endsAt > .now && region.contains($0.coordinate) }
            .sorted { $0.startsAt < $1.startsAt }
    }
    public func meet(_ id: MeetID) async throws -> Meet {
        guard let meet = meets[id], canSee(meet) else { throw WaypointsError.notFound }
        return meet
    }
    public func upcomingMeets(for user: UserID) async throws -> [Meet] {
        let ids = Set(rsvps.filter { $0.userID == user }.map(\.meetID))
        return meets.values.filter { ($0.hostID == user || ids.contains($0.id)) && $0.endsAt > .now && canSee($0) }
            .sorted { $0.startsAt < $1.startsAt }
    }
    public func rsvps(for meet: MeetID) async throws -> [MeetRSVP] { rsvps.filter { $0.meetID == meet } }
    public func myRSVP(for meet: MeetID) async throws -> MeetRSVP? {
        let me = try me()
        return rsvps.first { $0.meetID == meet && $0.userID == me }
    }
    public func setRSVP(_ status: RSVPStatus, for meet: MeetID, car: CarID?) async throws {
        let me = try me()
        rsvps.removeAll { $0.meetID == meet && $0.userID == me }
        rsvps.append(MeetRSVP(meetID: meet, userID: me, status: status, carID: car))
    }
    public func clearRSVP(for meet: MeetID) async throws {
        let me = try me()
        rsvps.removeAll { $0.meetID == meet && $0.userID == me }
    }
    public func venueNotes(near coordinate: Coordinate, meters: Int) async throws -> [VenueNote] {
        venueNotes.filter { $0.coordinate.distance(to: coordinate) <= Double(meters) }
    }
    public func addVenueNote(_ note: VenueNote) async throws -> VenueNote { venueNotes.append(note); return note }
}

extension PreviewStore: RoadRepository {
    public func roads(in region: MapRegion) async throws -> [Road] {
        roads.values.filter { $0.path.contains(where: region.contains) }
    }
    public func road(_ id: RoadID) async throws -> Road {
        guard let road = roads[id] else { throw WaypointsError.notFound }
        return road
    }
    public func roads(by author: UserID) async throws -> [Road] { roads.values.filter { $0.authorID == author } }
    public func createRoad(name: String, path: [Coordinate]) async throws -> Road {
        let length = zip(path, path.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        let road = Road(authorID: try me(), name: name, path: path, lengthMeters: Int(length))
        roads[road.id] = road
        return road
    }
    public func rate(_ road: RoadID, _ rating: RoadRating) async throws {
        roadRatings[Pair(road.raw, try me().raw)] = rating
        let all = roadRatings.filter { $0.key.a == road.raw }.map(\.value)
        let n = Double(all.count)
        roads[road]?.ratings = RoadRatingSummary(
            surface: all.map { Double($0.surface) }.reduce(0, +) / n,
            scenery: all.map { Double($0.scenery) }.reduce(0, +) / n,
            traffic: all.map { Double($0.traffic) }.reduce(0, +) / n,
            count: all.count)
    }
    public func myRating(for road: RoadID) async throws -> RoadRating? { roadRatings[Pair(road.raw, try me().raw)] }
}

extension PreviewStore: GatewayService {
    public func updatePrivacy(_ settings: PrivacySettings) async throws {
        guard settings.nearbyLevel != .precise else { throw WaypointsError.invalid("nearby_level") }
        privacy[try me()] = settings
    }
    public func postReport(kind: ReportKind, at coordinate: Coordinate, note: String?) async throws -> Report {
        let me = try me()
        if let existing = liveReports().first(where: { $0.kind == kind && $0.coordinate.distance(to: coordinate) <= 30 }) {
            reports[existing.id]?.confirmations += 1
            return reports[existing.id] ?? existing
        }
        let report = Report(authorID: me, kind: kind, coordinate: coordinate, note: note,
                            expiresAt: kind.lifetime.map { Date.now.addingTimeInterval($0) },
                            permanent: kind.lifetime == nil)
        reports[report.id] = report
        return report
    }
    public func undoReport(_ id: ReportID) async throws {
        guard reports[id]?.authorID == (try me()) else { throw WaypointsError.notFound }
        reports[id] = nil
    }
    public func voteReport(_ id: ReportID, stillThere: Bool) async throws {
        let me = try me()
        guard var report = reports[id] else { throw WaypointsError.notFound }
        reportVotes[Pair(id.raw, me.raw)] = stillThere
        if stillThere {
            report.confirmations += 1
            if let lifetime = report.kind.lifetime, !report.permanent {
                report.expiresAt = max(report.expiresAt ?? .now, .now.addingTimeInterval(lifetime))
            }
            reports[id] = report
        } else if reportVotes.filter({ $0.key.a == id.raw && !$0.value }).count >= 2 {
            reports[id] = nil
        }
    }
    public func helpRequests(in region: MapRegion) async throws -> [HelpRequest] {
        _ = try me()
        return helpStore.values.filter { $0.expiresAt > .now && ($0.isMine || region.contains($0.coordinate)) }
    }
    public func helpRequest(_ id: HelpRequestID) async throws -> HelpRequest {
        guard let r = helpStore[id], r.expiresAt > .now else { throw WaypointsError.notFound }
        return r
    }
    public func postHelp(_ draft: HelpDraft) async throws -> HelpRequest {
        let me = try me()
        guard !helpStore.values.contains(where: { $0.isMine && $0.expiresAt > .now }) else {
            throw WaypointsError.conflict("already active")
        }
        let r = HelpRequest(requesterID: me, kind: draft.kind, coordinate: draft.coordinate, note: draft.note,
                            showNearby: draft.showNearby, displayName: profiles[me]?.displayName, isMine: true)
        helpStore[r.id] = r
        return r
    }
    public func respondToHelp(_ id: HelpRequestID) async throws -> HelpRequest {
        _ = try me()
        guard var r = helpStore[id], !r.isMine else { throw WaypointsError.notFound }
        if !r.isComing { r.isComing = true; r.responderCount += 1 }
        helpStore[id] = r
        return r
    }
    public func endHelp(_ id: HelpRequestID) async throws {
        _ = try me()
        guard helpStore[id]?.isMine == true else { throw WaypointsError.notFound }
        helpStore[id] = nil
    }
    public func extendHelp(_ id: HelpRequestID) async throws -> HelpRequest {
        _ = try me()
        guard var r = helpStore[id], r.isMine else { throw WaypointsError.notFound }
        r.expiresAt = .now.addingTimeInterval(HelpRequest.lifetime)
        helpStore[id] = r
        return r
    }
    public func createMeet(_ draft: MeetDraft) async throws -> Meet {
        let me = try me()
        let today = meets.values.filter { $0.hostID == me && Calendar.current.isDateInToday($0.createdAt) }.count
        guard today < 3 else { throw WaypointsError.rateLimited }
        let meet = Meet(hostID: me, title: draft.title, kind: draft.kind, coordinate: draft.coordinate,
                        placeName: draft.placeName, startsAt: draft.startsAt, endsAt: draft.endsAt,
                        details: draft.details, visibility: draft.visibility, teamID: draft.teamID,
                        recurrence: draft.recurrence, seriesID: draft.recurrence == nil ? nil : UUID(),
                        destination: draft.destination)
        meets[meet.id] = meet
        return meet
    }
    public func updateMeet(_ id: MeetID, _ draft: MeetDraft) async throws -> Meet {
        let me = try me()
        guard var meet = meets[id] else { throw WaypointsError.notFound }
        guard meet.hostID == me else { throw WaypointsError.forbidden }
        meet.title = draft.title; meet.kind = draft.kind; meet.coordinate = draft.coordinate
        meet.placeName = draft.placeName; meet.startsAt = draft.startsAt; meet.endsAt = draft.endsAt
        meet.details = draft.details; meet.visibility = draft.visibility; meet.teamID = draft.teamID
        meet.recurrence = draft.recurrence; meet.destination = draft.destination
        if draft.recurrence != nil && meet.seriesID == nil { meet.seriesID = UUID() }
        meets[id] = meet
        return meet
    }
    public func cancelMeet(_ id: MeetID) async throws {
        let me = try me()
        guard meets[id]?.hostID == me else { throw WaypointsError.forbidden }
        meets[id]?.cancelledAt = .now
    }
    public func cancelMeetAndFollowing(_ id: MeetID) async throws {
        let me = try me()
        guard let meet = meets[id], meet.hostID == me else { throw WaypointsError.forbidden }
        for (key, m) in meets where m.id == id || (meet.seriesID != nil && m.seriesID == meet.seriesID && m.startsAt >= meet.startsAt) {
            meets[key]?.cancelledAt = m.cancelledAt ?? .now
            meets[key]?.recurrence = nil
        }
    }
    public func createConvoy(name: String, destination: ConvoyDestination?) async throws -> ConvoyInvite {
        _ = try me()
        let code = String((0..<6).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
        return ConvoyInvite(id: ConvoyID(raw: UUID().uuidString.lowercased()), joinCode: code)
    }
    public func joinConvoy(code: String) async throws -> ConvoyState {
        let me = try me()
        let uid = profiles[me]?.uid ?? 0
        return ConvoyState(id: ConvoyID(raw: "preview-\(code.lowercased())"), leaderUID: 2, memberUIDs: [2, 3, uid],
                           destination: ConvoyDestination(coordinate: PreviewSeed.meets[1].coordinate,
                                                          name: PreviewSeed.meets[1].placeName))
    }
    public func setConvoyDestination(_ id: ConvoyID, _ destination: ConvoyDestination) async throws { _ = try me() }
    public func setConvoyRegroup(_ id: ConvoyID, at coordinate: Coordinate) async throws { _ = try me() }
    public func endConvoy(_ id: ConvoyID) async throws { _ = try me() }
    public func inviteToConvoy(_ id: ConvoyID, users: [UserID]) async throws { _ = try me() }
    public func voiceToken(for channel: ChannelID) async throws -> VoiceCredentials {
        let me = try me()
        guard canRead(.channel(channel), as: me) else { throw WaypointsError.forbidden }
        return VoiceCredentials(url: URL(string: "wss://preview.livekit.invalid")!, token: "preview")
    }
    public func voiceToken(forConvoy convoy: ConvoyID) async throws -> VoiceCredentials {
        _ = try me()
        return VoiceCredentials(url: URL(string: "wss://preview.livekit.invalid")!, token: "preview")
    }
}
