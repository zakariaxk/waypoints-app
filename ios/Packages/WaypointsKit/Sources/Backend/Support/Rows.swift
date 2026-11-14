import Core
import Foundation

// Row shapes as PostgREST returns them (keys arrive snake_case and are converted by
// `Coders.decoder()`), and their mapping onto `Core` models. Section 5.

struct ProfileRow: Decodable, Sendable {
    let userId: UUID
    let uid: Int64
    let handle: String
    let displayName: String
    let bio: String?
    let avatarPath: String?
    let homeRegion: String?
    let markerIcon: String?
    let markerTrail: String?
    let primaryCarId: UUID?
    let birthYear: Int?
    let acceptedTermsAt: Date?
    let createdAt: Date

    var model: Profile {
        Profile(userID: UserID(raw: userId), uid: RealtimeUID(max(uid, 0)), handle: handle, displayName: displayName,
                bio: bio ?? "", avatarPath: avatarPath, homeRegion: homeRegion, markerIcon: markerIcon ?? "coupe",
                markerTrail: markerTrail, primaryCarID: primaryCarId.map(CarID.init(raw:)), birthYear: birthYear,
                acceptedTermsAt: acceptedTermsAt, createdAt: createdAt)
    }
}

struct PrivacyRow: Decodable, Sendable {
    let friendsLevel: PrivacyLevel
    let teamLevel: PrivacyLevel
    let nearbyLevel: PrivacyLevel
    let ghostUntil: Date?
    let notifyMeetsNearby: Bool
    let notifyRadiusKm: Int

    var model: PrivacySettings {
        PrivacySettings(friendsLevel: friendsLevel, teamLevel: teamLevel, nearbyLevel: nearbyLevel,
                        ghostUntil: ghostUntil, notifyMeetsNearby: notifyMeetsNearby, notifyRadiusKm: notifyRadiusKm)
    }
}

struct FriendshipRow: Decodable, Sendable {
    let requesterId: UUID
    let addresseeId: UUID
    let status: FriendshipStatus
    let createdAt: Date

    var model: Friendship {
        Friendship(requesterID: UserID(raw: requesterId), addresseeID: UserID(raw: addresseeId),
                   status: status, createdAt: createdAt)
    }
}

/// `cars.spec_overrides`. Keys match the seed: hp, torque, weight, drivetrain, redline, gears.
struct SpecRow: Codable, Sendable {
    var hp: Int?
    var torque: Int?
    var weight: Int?
    var drivetrain: Drivetrain?
    var redline: Int?
    var gears: [Double]?

    init(_ s: SpecOverrides) {
        hp = s.hp; torque = s.torqueLbFt; weight = s.weightLb; drivetrain = s.drivetrain
        redline = s.redline; gears = s.gears
    }

    var model: SpecOverrides {
        SpecOverrides(hp: hp, torqueLbFt: torque, weightLb: weight, drivetrain: drivetrain, redline: redline, gears: gears)
    }
}

struct CarRow: Decodable, Sendable {
    let id: UUID
    let ownerId: UUID
    let catalogVariantId: Int64?
    let year: Int
    let make: String
    let model: String
    let trim: String?
    let nickname: String?
    let colorFamily: String?
    let colorHex: String?
    let paintName: String?
    let clearance: Clearance
    let specOverrides: SpecRow?
    let mods: [String]?
    let sort: Int
    let createdAt: Date

    var car: Car {
        Car(id: CarID(raw: id), ownerID: UserID(raw: ownerId), catalogVariantID: catalogVariantId, year: year,
            make: make, model: model, trim: trim, nickname: nickname, colorFamily: colorFamily, colorHex: colorHex,
            paintName: paintName, clearance: clearance, specOverrides: specOverrides?.model ?? .init(),
            mods: mods ?? [], sort: sort, createdAt: createdAt)
    }
}

/// Body for inserting or fully updating a car. Every column is sent so `nil` clears it.
struct CarWrite: Encodable, Sendable {
    var ownerId: UUID?
    var catalogVariantId: Nullable<Int64>
    var year: Int
    var make: String
    var model: String
    var trim: Nullable<String>
    var nickname: Nullable<String>
    var colorFamily: Nullable<String>
    var colorHex: Nullable<String>
    var paintName: Nullable<String>
    var clearance: Clearance
    var specOverrides: SpecRow?
    var mods: [String]?
    var sort: Int?

    init(_ c: NewCar, owner: UserID, sort: Int) {
        ownerId = owner.raw; catalogVariantId = .init(c.catalogVariantID); year = c.year; make = c.make
        model = c.model; trim = .init(c.trim); nickname = .init(c.nickname); colorFamily = .init(c.colorFamily)
        colorHex = .init(c.colorHex); paintName = .init(c.paintName); clearance = c.clearance
        specOverrides = nil; mods = nil; self.sort = sort
    }

    init(_ c: Car) {
        ownerId = nil; catalogVariantId = .init(c.catalogVariantID); year = c.year; make = c.make
        model = c.model; trim = .init(c.trim); nickname = .init(c.nickname); colorFamily = .init(c.colorFamily)
        colorHex = .init(c.colorHex); paintName = .init(c.paintName); clearance = c.clearance
        specOverrides = SpecRow(c.specOverrides); mods = c.mods; sort = c.sort
    }
}

struct CarPhotoRow: Decodable, Sendable {
    let id: UUID
    let carId: UUID
    let path: String
    let width: Int?
    let height: Int?
    let sort: Int

    var model: CarPhoto {
        CarPhoto(id: CarPhotoID(raw: id), carID: CarID(raw: carId), path: path, width: width ?? 0,
                 height: height ?? 0, sort: sort)
    }
}

struct BuildEntryRow: Decodable, Sendable {
    let id: UUID
    let carId: UUID
    let happenedOn: Date
    let title: String
    let body: String?
    let photoPath: String?
    let modId: String?
    let isService: Bool?
    let odometer: Int?
    let odometerUnit: OdometerUnit?
    let remindOn: Date?
    let createdAt: Date

    var model: BuildEntry {
        BuildEntry(id: BuildEntryID(raw: id), carID: CarID(raw: carId), happenedOn: happenedOn, title: title,
                   body: body ?? "", photoPath: photoPath, modID: modId, isService: isService ?? false,
                   odometer: odometer, odometerUnit: odometerUnit, remindOn: remindOn, createdAt: createdAt)
    }
}

struct BuildEntryWrite: Encodable, Sendable {
    var id: UUID
    var carId: UUID
    var happenedOn: String
    var title: String
    var body: String
    var photoPath: Nullable<String>
    var modId: Nullable<String>
    var isService: Bool
    var odometer: Nullable<Int>
    var odometerUnit: Nullable<String>
    var remindOn: Nullable<String>

    init(_ e: BuildEntry) {
        id = e.id.raw; carId = e.carID.raw; happenedOn = PostgresDate.day(e.happenedOn); title = e.title
        body = e.body; photoPath = .init(e.photoPath); modId = .init(e.modID)
        isService = e.isService
        odometer = .init(e.isService ? e.odometer : nil)
        odometerUnit = .init(e.isService && e.odometer != nil ? e.odometerUnit?.rawValue : nil)
        remindOn = .init(e.isService ? e.remindOn.map(PostgresDate.day) : nil)
    }
}

// MARK: Map content

/// `reports_in_bbox` rows and `reports` table rows (`geom` as EWKB).
struct ReportRow: Decodable, Sendable {
    let id: UUID
    let authorId: UUID?
    let kind: ReportKind
    let latitude: Double?
    let longitude: Double?
    let geom: String?
    let note: String?
    let confirmations: Int
    let expiresAt: Date?
    let permanent: Bool
    let createdAt: Date?

    var model: Report {
        let coordinate = latitude.flatMap { lat in longitude.map { Coordinate(latitude: lat, longitude: $0) } }
            ?? geom.flatMap(Geo.point(fromEWKB:)) ?? Coordinate(latitude: 0, longitude: 0)
        return Report(id: ReportID(raw: id), authorID: UserID(raw: authorId ?? nilUUID), kind: kind,
                      coordinate: coordinate, note: note, confirmations: confirmations, expiresAt: expiresAt,
                      permanent: permanent, createdAt: createdAt ?? .distantPast)
    }
}

/// `meets_in_bbox` rows and `meets` table rows.
struct MeetRow: Decodable, Sendable {
    let id: UUID
    let hostId: UUID
    let title: String
    let kind: MeetKind
    let latitude: Double?
    let longitude: Double?
    let geom: String?
    let placeName: String?
    let startsAt: Date
    let endsAt: Date
    let details: String?
    let visibility: MeetVisibility
    let teamId: UUID?
    let cancelledAt: Date?
    let createdAt: Date?
    let recurrence: MeetRecurrence?
    let seriesId: UUID?
    let destLat: Double?
    let destLng: Double?
    let destName: String?
    let roadId: UUID?
    let winnerCarId: UUID?

    var model: Meet {
        let coordinate = latitude.flatMap { lat in longitude.map { Coordinate(latitude: lat, longitude: $0) } }
            ?? geom.flatMap(Geo.point(fromEWKB:)) ?? Coordinate(latitude: 0, longitude: 0)
        return Meet(id: MeetID(raw: id), hostID: UserID(raw: hostId), title: title, kind: kind, coordinate: coordinate,
                    placeName: placeName ?? "", startsAt: startsAt, endsAt: endsAt, details: details ?? "",
                    visibility: visibility, teamID: teamId.map(TeamID.init(raw:)), cancelledAt: cancelledAt,
                    createdAt: createdAt ?? .distantPast, recurrence: recurrence, seriesID: seriesId,
                    destination: destLat.flatMap { lat in destLng.map {
                        ConvoyDestination(coordinate: Coordinate(latitude: lat, longitude: $0), name: destName ?? "")
                    } }, roadID: roadId.map(RoadID.init(raw:)), winnerCarID: winnerCarId.map(CarID.init(raw:)))
    }
}

struct RSVPRow: Codable, Sendable {
    let meetId: UUID
    let userId: UUID
    let status: RSVPStatus
    let carId: UUID?
    /// NAV-15, migration 20261114060000. Absent before it is applied.
    var onTheWayUntil: Date?

    var model: MeetRSVP {
        MeetRSVP(meetID: MeetID(raw: meetId), userID: UserID(raw: userId), status: status,
                 carID: carId.map(CarID.init(raw:)), onTheWayUntil: onTheWayUntil)
    }
}

struct VenueNoteRow: Decodable, Sendable {
    let id: UUID
    let authorId: UUID
    let latitude: Double?
    let longitude: Double?
    let geom: String?
    let entrance: EntranceGrade?
    let lotSize: LotSize?
    let lit: Bool?
    let note: String?
    let createdAt: Date

    var model: VenueNote {
        let coordinate = latitude.flatMap { lat in longitude.map { Coordinate(latitude: lat, longitude: $0) } }
            ?? geom.flatMap(Geo.point(fromEWKB:)) ?? Coordinate(latitude: 0, longitude: 0)
        return VenueNote(id: VenueNoteID(raw: id), authorID: UserID(raw: authorId), coordinate: coordinate,
                         entrance: entrance ?? .flat, lotSize: lotSize ?? .medium, lit: lit ?? false, note: note,
                         createdAt: createdAt)
    }
}

/// `roads_in_bbox` rows (GeoJSON path and averages) and `roads` table rows (EWKB path).
struct RoadRow: Decodable, Sendable {
    let id: UUID
    let authorId: UUID
    let name: String
    let lengthM: Int?
    let pathGeojson: String?
    let path: String?
    let surfaceAvg: Double?
    let sceneryAvg: Double?
    let trafficAvg: Double?
    let ratingCount: Int?
    let createdAt: Date

    func model(ratings: RoadRatingSummary? = nil) -> Road {
        let coords = pathGeojson.map(Geo.coordinates(fromGeoJSON:)) ?? path.flatMap(Geo.coordinates(fromEWKB:)) ?? []
        let summary = ratings ?? RoadRatingSummary(surface: surfaceAvg ?? 0, scenery: sceneryAvg ?? 0,
                                                   traffic: trafficAvg ?? 0, count: ratingCount ?? 0)
        return Road(id: RoadID(raw: id), authorID: UserID(raw: authorId), name: name, path: coords,
                    lengthMeters: lengthM ?? Geo.length(of: coords), ratings: summary, createdAt: createdAt)
    }
}

struct RoadRatingRow: Codable, Sendable {
    let surface: Int
    let scenery: Int
    let traffic: Int
}

struct SpotRow: Decodable, Sendable {
    let id: UUID
    let spotterId: UUID
    let catalogModelId: Int64?
    let year: Int?
    let make: String
    let model: String
    let photoPath: String?
    let city: String?
    let createdAt: Date

    var spot: Spot {
        Spot(id: SpotID(raw: id), spotterID: UserID(raw: spotterId), catalogModelID: catalogModelId ?? 0, year: year,
             make: make, model: model, photoPath: photoPath ?? "", city: city ?? "", createdAt: createdAt)
    }
}

// MARK: Teams and messaging

struct CountRow: Decodable, Sendable { let count: Int }

struct TeamRow: Decodable, Sendable {
    let id: UUID
    let ownerId: UUID
    let name: String
    let tag: String
    let about: String?
    let iconPath: String?
    let isPublic: Bool
    let inviteCode: String?
    let createdAt: Date
    let teamMembers: [CountRow]?

    var model: Team {
        Team(id: TeamID(raw: id), ownerID: UserID(raw: ownerId), name: name, tag: tag, about: about ?? "",
             iconPath: iconPath, isPublic: isPublic, inviteCode: inviteCode,
             memberCount: teamMembers?.first?.count ?? 0, createdAt: createdAt)
    }
}

/// Teams with the member count embedded.
let teamColumns = "*, team_members(count)"

struct TeamRoleRow: Decodable, Sendable {
    let id: UUID
    let teamId: UUID
    let name: String
    let colorHex: String?
    let rank: Int
    let permissions: Int

    var model: TeamRole {
        TeamRole(id: TeamRoleID(raw: id), teamID: TeamID(raw: teamId), name: name, colorHex: colorHex, rank: rank,
                 permissions: TeamPermissions(rawValue: permissions))
    }
}

struct TeamMemberRow: Decodable, Sendable {
    let teamId: UUID
    let userId: UUID
    let roleId: UUID?
    let joinedAt: Date

    var model: TeamMember {
        TeamMember(teamID: TeamID(raw: teamId), userID: UserID(raw: userId), roleID: roleId.map(TeamRoleID.init(raw:)),
                   joinedAt: joinedAt)
    }
}

struct ChannelRow: Decodable, Sendable {
    let id: UUID
    let teamId: UUID
    let name: String
    let kind: ChannelKind
    let sort: Int

    var model: Channel {
        Channel(id: ChannelID(raw: id), teamID: TeamID(raw: teamId), name: name, kind: kind, sort: sort)
    }
}

struct ThreadRow: Decodable, Sendable {
    let id: UUID
    let kind: ThreadKind
    let listingId: UUID?
    let aId: UUID
    let bId: UUID
    let createdAt: Date

    func model(lastMessage: Message? = nil, unread: Int = 0) -> MessageThread {
        MessageThread(id: ThreadID(raw: id), kind: kind, listingID: listingId.map(ListingID.init(raw:)),
                      aID: UserID(raw: aId), bID: UserID(raw: bId), lastMessage: lastMessage, unreadCount: unread,
                      createdAt: createdAt)
    }
}

struct MessageRow: Decodable, Sendable {
    let id: Int64
    let channelId: UUID?
    let threadId: UUID?
    let authorId: UUID
    let body: String?
    let attachmentPath: String?
    let deletedAt: Date?
    let createdAt: Date

    var model: Message? {
        let target: MessageTarget
        if let channelId { target = .channel(ChannelID(raw: channelId)) }
        else if let threadId { target = .thread(ThreadID(raw: threadId)) }
        else { return nil }
        return Message(id: MessageID(raw: id), target: target, authorID: UserID(raw: authorId), body: body ?? "",
                       attachmentPath: attachmentPath, deletedAt: deletedAt, createdAt: createdAt)
    }
}

struct ReadMarkerRow: Decodable, Sendable {
    let channelId: UUID?
    let threadId: UUID?
    let lastReadMessageId: Int64
}

// MARK: Feed, Showdown, Market, Progress

struct PostRow: Decodable, Sendable {
    /// Posts with their photos embedded (FEED-11).
    static let columns = "*, post_photos(path, sort)"
    struct Photo: Decodable, Sendable { let path: String; let sort: Int }
    let id: UUID
    let authorId: UUID
    let carId: UUID?
    let meetId: UUID?
    let videoPath: String?
    let postPhotos: [Photo]?
    let posterPath: String?
    let caption: String?
    let durationMs: Int?
    let likeCount: Int
    let commentCount: Int
    let createdAt: Date

    func model(liked: Bool) -> Post {
        Post(id: PostID(raw: id), authorID: UserID(raw: authorId), carID: carId.map(CarID.init(raw:)),
             meetID: meetId.map(MeetID.init(raw:)), videoPath: videoPath,
             photoPaths: (postPhotos ?? []).sorted { $0.sort < $1.sort }.map(\.path), posterPath: posterPath ?? "", caption: caption ?? "", durationMs: durationMs ?? 0,
             likeCount: likeCount, commentCount: commentCount, likedByMe: liked, createdAt: createdAt)
    }
}

struct CommentRow: Decodable, Sendable {
    let id: UUID
    let postId: UUID
    let authorId: UUID
    let body: String
    let createdAt: Date

    var model: PostComment {
        PostComment(id: CommentID(raw: id), postID: PostID(raw: postId), authorID: UserID(raw: authorId), body: body,
                    createdAt: createdAt)
    }
}

struct ShowdownRow: Decodable, Sendable {
    let carId: UUID
    let rating: Int
    let wins: Int
    let losses: Int
    let `class`: ShowdownClass

    var model: ShowdownEntry {
        ShowdownEntry(carID: CarID(raw: carId), rating: rating, wins: wins, losses: losses, showdownClass: `class`)
    }
}

struct ListingPhotoRow: Decodable, Sendable {
    let id: UUID
    let path: String
    let sort: Int

    var model: ListingPhoto { ListingPhoto(id: ListingPhotoID(raw: id), path: path, sort: sort) }
}

struct ListingRow: Decodable, Sendable {
    let id: UUID
    let sellerId: UUID
    let kind: ListingKind
    let title: String
    let priceCents: Int
    let condition: ListingCondition
    let description: String?
    let fitsMake: String?
    let fitsModel: String?
    let fitsYearFrom: Int?
    let fitsYearTo: Int?
    let carId: UUID?
    let region: String?
    let status: ListingStatus
    let createdAt: Date
    let listingPhotos: [ListingPhotoRow]?
    let category: ListingCategory?
    let updatedAt: Date?

    func model(saved: Bool) -> Listing {
        let fits = fitsMake.map { Fitment(make: $0, model: fitsModel, yearFrom: fitsYearFrom, yearTo: fitsYearTo) }
        return Listing(id: ListingID(raw: id), sellerID: UserID(raw: sellerId), kind: kind, title: title,
                       priceCents: priceCents, condition: condition, description: description ?? "", fits: fits,
                       carID: carId.map(CarID.init(raw:)), region: region ?? "", status: status,
                       photos: (listingPhotos ?? []).map(\.model).sorted { $0.sort < $1.sort }, savedByMe: saved,
                       createdAt: createdAt, category: category, updatedAt: updatedAt)
    }
}

/// Listings with their photos embedded.
let listingColumns = "*, listing_photos(id, path, sort)"

struct ListingWrite: Encodable, Sendable {
    var sellerId: UUID?
    var kind: ListingKind
    var title: String
    var priceCents: Int
    var condition: ListingCondition
    var description: String
    var fitsMake: Nullable<String>
    var fitsModel: Nullable<String>
    var fitsYearFrom: Nullable<Int>
    var fitsYearTo: Nullable<Int>
    var carId: Nullable<UUID>
    var region: String
    var status: ListingStatus?
    var category: Nullable<ListingCategory>
    /// Coarse position (MKT-1): rounded to 0.1 degree; omitted on update so an edit keeps it.
    var latC: Double?
    var lngC: Double?

    init(kind: ListingKind, title: String, priceCents: Int, condition: ListingCondition, description: String,
         fits: Fitment?, carID: CarID?, region: String, seller: UserID?, status: ListingStatus?,
         category: ListingCategory? = nil, near: Coordinate? = nil) {
        self.category = .init(category)
        latC = near.map { ($0.latitude * 10).rounded() / 10 }
        lngC = near.map { ($0.longitude * 10).rounded() / 10 }
        sellerId = seller?.raw; self.kind = kind; self.title = title; self.priceCents = priceCents
        self.condition = condition; self.description = description
        fitsMake = .init(fits?.make); fitsModel = .init(fits?.model); fitsYearFrom = .init(fits?.yearFrom)
        fitsYearTo = .init(fits?.yearTo); carId = .init(carID?.raw); self.region = region; self.status = status
    }
}

struct AchievementRow: Decodable, Sendable {
    let userId: UUID
    let key: String
    let earnedAt: Date

    var model: Achievement { Achievement(userID: UserID(raw: userId), key: key, earnedAt: earnedAt) }
}

struct RaceResultRow: Decodable, Sendable {
    let id: UUID
    let userId: UUID
    let carId: UUID
    let mods: [String]?
    let reactionMs: Int?
    let etMs: Int
    let trapMphX10: Int?
    let sixtyFtMs: Int?
    let inputLog: String?
    let createdAt: Date

    var model: RaceResult {
        RaceResult(id: RaceResultID(raw: id), userID: UserID(raw: userId), carID: CarID(raw: carId), mods: mods ?? [],
                   reactionMs: reactionMs ?? 0, etMs: etMs, trapMphX10: trapMphX10 ?? 0, sixtyFtMs: sixtyFtMs ?? 0,
                   inputLog: Bytea.decode(inputLog), createdAt: createdAt)
    }
}

/// `select id` results.
struct IDRow: Decodable, Sendable { let id: UUID }

/// Placeholder for columns an RPC does not return (for example `hazards_along` has no author).
let nilUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
