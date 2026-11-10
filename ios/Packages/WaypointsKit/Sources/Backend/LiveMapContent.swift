import Core
import Foundation
import Supabase

/// Arguments of the `*_in_bbox` RPCs.
private struct BBox: Encodable, Sendable {
    let minLng: Double, minLat: Double, maxLng: Double, maxLat: Double
    init(_ r: MapRegion) {
        minLng = r.minLongitude; minLat = r.minLatitude; maxLng = r.maxLongitude; maxLat = r.maxLatitude
    }
}

/// `meets` (read; writes go through the gateway), `meet_rsvps`, `venue_notes`.
struct LiveMeets: MeetRepository {
    let ctx: BackendContext

    func meets(in region: MapRegion) async throws -> [Meet] {
        try await ctx.run {
            let rows: [MeetRow] = try await ctx.client.rpc("meets_in_bbox", params: BBox(region)).execute().value
            return rows.map(\.model)
        }
    }

    func meet(_ id: MeetID) async throws -> Meet {
        try await ctx.run {
            let row: MeetRow = try await ctx.table("meets").select().eq("id", value: id.key).single().execute().value
            return row.model
        }
    }

    func upcomingMeets(for user: UserID) async throws -> [Meet] {
        try await ctx.run {
            struct Row: Decodable { let meetId: UUID }
            let rsvps: [Row] = try await ctx.table("meet_rsvps").select("meet_id").eq("user_id", value: user.key)
                .execute().value
            var filter = "host_id.eq.\(user.key)"
            if !rsvps.isEmpty {
                filter += ",id.in.(\(rsvps.map { $0.meetId.uuidString.lowercased() }.joined(separator: ",")))"
            }
            let rows: [MeetRow] = try await ctx.table("meets").select().or(filter)
                .gt("ends_at", value: Date.now).is("cancelled_at", value: nil)
                .order("starts_at").limit(100).execute().value
            return rows.map(\.model)
        }
    }

    func rsvps(for meet: MeetID) async throws -> [MeetRSVP] {
        try await ctx.run {
            let rows: [RSVPRow] = try await ctx.table("meet_rsvps").select().eq("meet_id", value: meet.key)
                .order("created_at").execute().value
            return rows.map(\.model)
        }
    }

    func myRSVP(for meet: MeetID) async throws -> MeetRSVP? {
        let me = try ctx.me()
        return try await ctx.run {
            let rows: [RSVPRow] = try await ctx.table("meet_rsvps").select().eq("meet_id", value: meet.key)
                .eq("user_id", value: me.key).limit(1).execute().value
            return rows.first?.model
        }
    }

    func setRSVP(_ status: RSVPStatus, for meet: MeetID, car: CarID?) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let meetId: UUID; let userId: UUID; let status: RSVPStatus; let carId: Nullable<UUID> }
        try await ctx.run {
            _ = try await ctx.table("meet_rsvps")
                .upsert(Body(meetId: meet.raw, userId: me.raw, status: status, carId: .init(car?.raw)),
                        onConflict: "meet_id,user_id", returning: .minimal)
                .execute()
        }
    }

    func clearRSVP(for meet: MeetID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("meet_rsvps").delete(returning: .minimal).eq("meet_id", value: meet.key)
                .eq("user_id", value: me.key).execute()
        }
    }

    func venueNotes(near coordinate: Coordinate, meters: Int) async throws -> [VenueNote] {
        struct Params: Encodable { let lng: Double; let lat: Double; let meters: Int }
        return try await ctx.run {
            let rows: [VenueNoteRow] = try await ctx.client
                .rpc("venue_notes_near", params: Params(lng: coordinate.longitude, lat: coordinate.latitude, meters: meters))
                .execute().value
            return rows.map(\.model)
        }
    }

    func addVenueNote(_ note: VenueNote) async throws -> VenueNote {
        let me = try ctx.me()
        struct Body: Encodable {
            let id: UUID; let authorId: UUID; let geom: String; let entrance: EntranceGrade; let lotSize: LotSize
            let lit: Bool; let note: Nullable<String>
        }
        let body = Body(id: note.id.raw, authorId: me.raw, geom: Geo.ewkt(note.coordinate), entrance: note.entrance,
                        lotSize: note.lotSize, lit: note.lit, note: .init(note.note))
        return try await ctx.run {
            let row: VenueNoteRow = try await ctx.table("venue_notes").insert(body, returning: .representation)
                .select().single().execute().value
            return row.model
        }
    }
}

/// `reports` (read). Posting and voting go through the gateway.
struct LiveReports: ReportRepository {
    let ctx: BackendContext

    func reports(in region: MapRegion) async throws -> [Report] {
        try await ctx.run {
            let rows: [ReportRow] = try await ctx.client.rpc("reports_in_bbox", params: BBox(region)).execute().value
            return rows.map(\.model)
        }
    }

    func report(_ id: ReportID) async throws -> Report {
        try await ctx.run {
            let row: ReportRow = try await ctx.table("reports").select().eq("id", value: id.key).single().execute().value
            return row.model
        }
    }

    func hazards(along path: [Coordinate], bufferMeters: Int) async throws -> [Report] {
        guard path.count >= 2 else { return [] }
        struct Params: Encodable { let path: String; let bufferM: Int }
        return try await ctx.run {
            let rows: [ReportRow] = try await ctx.client
                .rpc("hazards_along", params: Params(path: Geo.ewkt(path), bufferM: bufferMeters)).execute().value
            return rows.map(\.model)
        }
    }

    /// `report_votes` is service-role only (section 5.3), so the client cannot read its own
    /// vote back; features keep the choice locally after voting through the gateway.
    func myVote(on report: ReportID) async throws -> Bool? { nil }
}

/// `roads`, `road_ratings`.
struct LiveRoads: RoadRepository {
    let ctx: BackendContext

    func roads(in region: MapRegion) async throws -> [Road] {
        try await ctx.run {
            let rows: [RoadRow] = try await ctx.client.rpc("roads_in_bbox", params: BBox(region)).execute().value
            return rows.map { $0.model() }
        }
    }

    private func summary(_ road: UUID) async throws -> RoadRatingSummary {
        let ratings: [RoadRatingRow] = try await ctx.table("road_ratings").select("surface, scenery, traffic")
            .eq("road_id", value: road).execute().value
        guard !ratings.isEmpty else { return RoadRatingSummary() }
        let n = Double(ratings.count)
        func avg(_ k: KeyPath<RoadRatingRow, Int>) -> Double {
            (Double(ratings.reduce(0) { $0 + $1[keyPath: k] }) / n * 10).rounded() / 10
        }
        return RoadRatingSummary(surface: avg(\.surface), scenery: avg(\.scenery), traffic: avg(\.traffic),
                                 count: ratings.count)
    }

    func road(_ id: RoadID) async throws -> Road {
        try await ctx.run {
            let row: RoadRow = try await ctx.table("roads").select().eq("id", value: id.key).single().execute().value
            return row.model(ratings: try await summary(row.id))
        }
    }

    func roads(by author: UserID) async throws -> [Road] {
        try await ctx.run {
            let rows: [RoadRow] = try await ctx.table("roads").select().eq("author_id", value: author.key)
                .order("created_at", ascending: false).execute().value
            var out: [Road] = []
            for row in rows { out.append(row.model(ratings: try await summary(row.id))) }
            return out
        }
    }

    func createRoad(name: String, path: [Coordinate]) async throws -> Road {
        let me = try ctx.me()
        guard path.count >= 2 else { throw WaypointsError.invalid("path") }
        struct Body: Encodable { let authorId: UUID; let name: String; let path: String; let lengthM: Int }
        return try await ctx.run {
            let row: RoadRow = try await ctx.table("roads")
                .insert(Body(authorId: me.raw, name: name, path: Geo.ewkt(path), lengthM: Geo.length(of: path)),
                        returning: .representation)
                .select().single().execute().value
            return row.model(ratings: RoadRatingSummary())
        }
    }

    func rate(_ road: RoadID, _ rating: RoadRating) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let roadId: UUID; let userId: UUID; let surface: Int; let scenery: Int; let traffic: Int }
        let clamp = { (v: Int) in min(max(v, 1), 5) }
        try await ctx.run {
            _ = try await ctx.table("road_ratings")
                .upsert(Body(roadId: road.raw, userId: me.raw, surface: clamp(rating.surface),
                             scenery: clamp(rating.scenery), traffic: clamp(rating.traffic)),
                        onConflict: "road_id,user_id", returning: .minimal)
                .execute()
        }
    }

    func myRating(for road: RoadID) async throws -> RoadRating? {
        let me = try ctx.me()
        return try await ctx.run {
            let rows: [RoadRatingRow] = try await ctx.table("road_ratings").select("surface, scenery, traffic")
                .eq("road_id", value: road.key).eq("user_id", value: me.key).limit(1).execute().value
            return rows.first.map { RoadRating(surface: $0.surface, scenery: $0.scenery, traffic: $0.traffic) }
        }
    }
}

/// `spots`. City level only; there is no coordinate column to leak.
struct LiveSpots: SpotRepository {
    let ctx: BackendContext

    func spots(by spotter: UserID) async throws -> [Spot] {
        try await ctx.run {
            let rows: [SpotRow] = try await ctx.table("spots").select().eq("spotter_id", value: spotter.key)
                .order("created_at", ascending: false).execute().value
            return rows.map(\.spot)
        }
    }

    func addSpot(_ spot: Spot) async throws -> Spot {
        let me = try ctx.me()
        struct Body: Encodable {
            let id: UUID; let spotterId: UUID; let catalogModelId: Int64?; let year: Int?; let make: String
            let model: String; let photoPath: String?; let city: String?
        }
        let body = Body(id: spot.id.raw, spotterId: me.raw, catalogModelId: spot.catalogModelID > 0 ? spot.catalogModelID : nil,
                        year: spot.year, make: spot.make, model: spot.model,
                        photoPath: spot.photoPath.isEmpty ? nil : spot.photoPath, city: spot.city.isEmpty ? nil : spot.city)
        return try await ctx.run {
            let row: SpotRow = try await ctx.table("spots").insert(body, returning: .representation)
                .select().single().execute().value
            return row.spot
        }
    }

    /// The schema revokes delete on `spots` (section 5.3: "Insert: owner"), so this throws
    /// `forbidden` until a migration grants it.
    func deleteSpot(_ id: SpotID) async throws {
        try await ctx.run {
            _ = try await ctx.table("spots").delete(returning: .minimal).eq("id", value: id.key).execute()
        }
    }
}
