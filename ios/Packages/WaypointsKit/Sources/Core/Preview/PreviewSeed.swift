import Foundation

/// Seed data for `PreviewEnvironment`: South Jersey and Philadelphia, real cars, plausible people.
/// Deterministic ids so previews and debug screens can refer to them.
public enum PreviewSeed {
    // MARK: Helpers

    static func uuid(_ n: Int, _ kind: Int) -> UUID {
        UUID(uuidString: String(format: "%08X-0000-4000-8000-%012X", kind, n))!
    }
    static func user(_ n: Int) -> UserID { UserID(raw: uuid(n, 1)) }
    static func car(_ n: Int) -> CarID { CarID(raw: uuid(n, 2)) }
    static func at(_ lat: Double, _ lng: Double) -> Coordinate { Coordinate(latitude: lat, longitude: lng) }
    static func hours(_ h: Double, from base: Date = reference) -> Date { base.addingTimeInterval(h * 3600) }

    /// Seed timestamps are relative to launch so meets are always upcoming.
    static let reference = Date.now
    static let today: Date = Calendar.current.startOfDay(for: reference)

    /// Cherry Hill, NJ.
    public static let center = at(39.9348, -75.0307)
    public static let region = MapRegion(center: center, latitudeDelta: 0.25, longitudeDelta: 0.3)

    // MARK: People

    public static let maya = user(1)
    public static let devon = user(2)
    public static let jae = user(3)
    public static let rosa = user(4)
    public static let theo = user(5)
    public static let nina = user(6)
    public static let marcus = user(7)
    public static let lena = user(8)
    public static let sam = user(9)
    public static let chris = user(10)

    /// The signed-in user in previews.
    public static let me = maya

    public static let profiles: [Profile] = [
        Profile(userID: maya, uid: 1, handle: "mayadrives", displayName: "Maya Ortiz",
                bio: "S550 on coilovers. Sunday mornings on 563.", homeRegion: "South Jersey",
                markerIcon: "pony", primaryCarID: car(1), birthYear: 1997, acceptedTermsAt: hours(-24 * 40)),
        Profile(userID: devon, uid: 2, handle: "dev_e46", displayName: "Devon Price",
                bio: "Two BMWs, one of them runs.", homeRegion: "Cherry Hill",
                markerIcon: "sedan", primaryCarID: car(2), birthYear: 1993, acceptedTermsAt: hours(-24 * 90)),
        Profile(userID: jae, uid: 3, handle: "jpark_si", displayName: "Jae Park",
                bio: "EM1 Si, B16 swap in progress.", homeRegion: "Haddonfield",
                markerIcon: "coupe", primaryCarID: car(4), birthYear: 2000, acceptedTermsAt: hours(-24 * 60)),
        Profile(userID: rosa, uid: 4, handle: "rosa_wrx", displayName: "Rosa Delgado",
                bio: "Rally fan. Runs the South Jersey Subies cruise.", homeRegion: "Medford",
                markerIcon: "sedan", primaryCarID: car(5), birthYear: 1995, acceptedTermsAt: hours(-24 * 120)),
        Profile(userID: theo, uid: 5, handle: "tkowalski", displayName: "Theo Kowalski",
                bio: "Numbers-matching 396. Shows only, no burnouts.", homeRegion: "Collingswood",
                markerIcon: "muscle", primaryCarID: car(6), birthYear: 1968, acceptedTermsAt: hours(-24 * 30)),
        Profile(userID: nina, uid: 6, handle: "nina_gr86", displayName: "Nina Shah",
                bio: "Track days at NJMP. Learning to heel-toe.", homeRegion: "Voorhees",
                markerIcon: "coupe", primaryCarID: car(7), birthYear: 1999, acceptedTermsAt: hours(-24 * 15)),
        Profile(userID: marcus, uid: 7, handle: "marcus_trx", displayName: "Marcus Bell",
                bio: "Tows the project cars.", homeRegion: "South Philly",
                markerIcon: "pickup", primaryCarID: car(8), birthYear: 1990, acceptedTermsAt: hours(-24 * 200)),
        Profile(userID: lena, uid: 8, handle: "lena_na", displayName: "Lena Fischer",
                bio: "NA Miata, top down until November.", homeRegion: "Moorestown",
                markerIcon: "roadster", primaryCarID: car(9), birthYear: 1996, acceptedTermsAt: hours(-24 * 75)),
        Profile(userID: sam, uid: 9, handle: "sam_gti", displayName: "Sam Okafor",
                bio: "Mk7 GTI, daily and weekend.", homeRegion: "Mount Laurel",
                markerIcon: "hatch", primaryCarID: car(10), birthYear: 1998, acceptedTermsAt: hours(-24 * 10)),
        Profile(userID: chris, uid: 10, handle: "chris_z33", displayName: "Chris Romano",
                bio: "350Z, VQ noises.", homeRegion: "Deptford",
                markerIcon: "coupe", primaryCarID: car(11), birthYear: 1994, acceptedTermsAt: hours(-24 * 50)),
    ]

    public static let privacy: [UserID: PrivacySettings] = [
        maya: PrivacySettings(friendsLevel: .precise, teamLevel: .approx, nearbyLevel: .hidden,
                              notifyMeetsNearby: true, notifyRadiusKm: 25),
    ]

    // MARK: Garage

    public static let cars: [Car] = [
        Car(id: car(1), ownerID: maya, catalogVariantID: 1001, year: 2019, make: "Ford", model: "Mustang", trim: "GT",
            colorFamily: "blue", colorHex: "#2B4C7E", paintName: "Velocity Blue", clearance: .lowered,
            specOverrides: SpecOverrides(hp: 460), mods: ["intake.cai", "exhaust.catback", "suspension.coilovers"]),
        Car(id: car(2), ownerID: devon, catalogVariantID: 1002, year: 2004, make: "BMW", model: "330i", trim: nil,
            nickname: "The E46", colorFamily: "silver", colorHex: "#A7A9AC", paintName: "Titanium Silver",
            mods: ["wheels.style68"]),
        Car(id: car(3), ownerID: devon, catalogVariantID: 1003, year: 2020, make: "Toyota", model: "GR Supra", trim: "3.0",
            colorFamily: "red", colorHex: "#B11226", paintName: "Renaissance Red 2.0", sort: 1),
        Car(id: car(4), ownerID: jae, catalogVariantID: 1004, year: 1999, make: "Honda", model: "Civic", trim: "Si",
            colorFamily: "blue", colorHex: "#2F5DA8", paintName: "Electron Blue Pearl", clearance: .slammed,
            mods: ["suspension.coilovers", "wheels.te37"]),
        Car(id: car(5), ownerID: rosa, catalogVariantID: 1005, year: 2015, make: "Subaru", model: "WRX", trim: "Premium",
            colorFamily: "blue", colorHex: "#1E3F8A", paintName: "WR Blue Pearl", mods: ["tune.stage1", "intake.cai"]),
        Car(id: car(6), ownerID: theo, catalogVariantID: 1006, year: 1969, make: "Chevrolet", model: "Camaro", trim: "SS 396",
            colorFamily: "orange", colorHex: "#E2591B", paintName: "Hugger Orange"),
        Car(id: car(7), ownerID: nina, catalogVariantID: 1007, year: 2022, make: "Toyota", model: "GR86", trim: "Premium",
            colorFamily: "red", colorHex: "#C1121F", paintName: "Track bRed", mods: ["tires.re71rs"]),
        Car(id: car(8), ownerID: marcus, catalogVariantID: 1008, year: 2021, make: "Ram", model: "1500", trim: "TRX",
            colorFamily: "black", colorHex: "#141414", paintName: "Diamond Black"),
        Car(id: car(9), ownerID: lena, catalogVariantID: 1009, year: 1995, make: "Mazda", model: "MX-5 Miata", trim: nil,
            colorFamily: "green", colorHex: "#1F4E3D", paintName: "Montego Blue", clearance: .lowered),
        Car(id: car(10), ownerID: sam, catalogVariantID: 1010, year: 2018, make: "Volkswagen", model: "Golf GTI", trim: "SE",
            colorFamily: "red", colorHex: "#C8102E", paintName: "Tornado Red"),
        Car(id: car(11), ownerID: chris, catalogVariantID: 1011, year: 2005, make: "Nissan", model: "350Z", trim: "Track",
            colorFamily: "blue", colorHex: "#24418F", paintName: "Daytona Blue"),
        Car(id: car(12), ownerID: maya, catalogVariantID: 1012, year: 2017, make: "Honda", model: "Civic", trim: "Type R",
            nickname: "Weekday car", colorFamily: "white", colorHex: "#F2F2F0", paintName: "Championship White", sort: 1),
    ]

    public static let carPhotos: [CarPhoto] = cars.enumerated().map { index, car in
        CarPhoto(id: CarPhotoID(raw: uuid(index + 1, 3)), carID: car.id,
                 path: "\(car.ownerID)/\(car.id)/1.jpg", width: 2048, height: 1365)
    }

    public static let buildEntries: [BuildEntry] = [
        BuildEntry(carID: car(1), happenedOn: hours(-24 * 300, from: today), title: "Picked it up",
                   body: "Bought it with 11k miles from a dealer in Pennsauken."),
        BuildEntry(carID: car(1), happenedOn: hours(-24 * 200, from: today), title: "Cold air intake",
                   body: "JLT intake. Louder on the highway, not much else.", modID: "intake.cai"),
        BuildEntry(carID: car(1), happenedOn: hours(-24 * 90, from: today), title: "Coilovers",
                   body: "Dropped 1.5 inches. Watching for speed bumps now.", modID: "suspension.coilovers"),
        BuildEntry(carID: car(4), happenedOn: hours(-24 * 45, from: today), title: "B16 out for rebuild",
                   body: "New rings and bearings. Head is at the machine shop."),
    ]

    // MARK: Friends

    public static let friendships: [Friendship] = [
        Friendship(requesterID: maya, addresseeID: devon, status: .accepted, createdAt: hours(-24 * 200)),
        Friendship(requesterID: jae, addresseeID: maya, status: .accepted, createdAt: hours(-24 * 120)),
        Friendship(requesterID: maya, addresseeID: rosa, status: .accepted, createdAt: hours(-24 * 80)),
        Friendship(requesterID: nina, addresseeID: maya, status: .accepted, createdAt: hours(-24 * 20)),
        Friendship(requesterID: sam, addresseeID: maya, status: .pending, createdAt: hours(-5)),
        Friendship(requesterID: maya, addresseeID: chris, status: .pending, createdAt: hours(-30)),
    ]

    // MARK: Map content

    public static let meets: [Meet] = [
        Meet(id: MeetID(raw: uuid(1, 4)), hostID: devon, title: "Cars and coffee", kind: .meet,
             coordinate: at(39.9405, -75.0094), placeName: "Cherry Hill Mall, east lot",
             startsAt: hours(32, from: today), endsAt: hours(35, from: today),
             details: "Park nose-in along the light poles. Coffee from the Wawa across 38."),
        Meet(id: MeetID(raw: uuid(2, 4)), hostID: rosa, title: "Pine Barrens cruise", kind: .cruise,
             coordinate: at(39.8950, -74.8190), placeName: "Wawa, Route 70, Medford",
             startsAt: hours(24 * 3 + 9, from: today), endsAt: hours(24 * 3 + 13, from: today),
             details: "Out 532 to 563, lunch in Chatsworth. No pulls, keep the group together."),
        Meet(id: MeetID(raw: uuid(3, 4)), hostID: jae, title: "Thursday night hangout", kind: .hangout,
             coordinate: at(39.8970, -75.0370), placeName: "Haddonfield train station lot",
             startsAt: hours(-0.5), endsAt: hours(2.5),
             details: "Low cars welcome; the entrance on Washington Ave is the flat one."),
        Meet(id: MeetID(raw: uuid(4, 4)), hostID: theo, title: "Cooper River classics", kind: .show,
             coordinate: at(39.9283, -75.0610), placeName: "Cooper River Park, North Park Drive",
             startsAt: hours(24 * 9 + 10, from: today), endsAt: hours(24 * 9 + 15, from: today),
             details: "Pre-1990 only on the grass. Everything else in the lot."),
        Meet(id: MeetID(raw: uuid(5, 4)), hostID: nina, title: "Thunderbolt open lapping", kind: .trackDay,
             coordinate: at(39.3610, -75.0700), placeName: "New Jersey Motorsports Park, Millville",
             startsAt: hours(24 * 12 + 8, from: today), endsAt: hours(24 * 12 + 17, from: today),
             details: "Helmet and tech sheet required. Carpool from Voorhees at 6."),
        Meet(id: MeetID(raw: uuid(6, 4)), hostID: marcus, title: "Waterfront night meet", kind: .meet,
             coordinate: at(39.9179, -75.1400), placeName: "Pier 70 lot, Columbus Blvd",
             startsAt: hours(24 * 2 + 21, from: today), endsAt: hours(24 * 2 + 23.5, from: today),
             details: "Engines off once parked. Security closes the lot at midnight."),
    ]

    public static let rsvps: [MeetRSVP] = [
        MeetRSVP(meetID: meets[0].id, userID: maya, status: .going, carID: car(1)),
        MeetRSVP(meetID: meets[0].id, userID: jae, status: .going, carID: car(4), onTheWayUntil: .now.addingTimeInterval(20 * 60)),
        MeetRSVP(meetID: meets[0].id, userID: nina, status: .maybe),
        MeetRSVP(meetID: meets[1].id, userID: lena, status: .going, carID: car(9)),
        MeetRSVP(meetID: meets[2].id, userID: devon, status: .going, carID: car(2)),
    ]

    public static let reports: [Report] = [
        Report(id: ReportID(raw: uuid(1, 5)), authorID: jae, kind: .speedBump, coordinate: at(39.8992, -75.0331),
               confirmations: 6, permanent: true, createdAt: hours(-24 * 20)),
        Report(id: ReportID(raw: uuid(2, 5)), authorID: jae, kind: .speedBump, coordinate: at(39.8981, -75.0352),
               confirmations: 3, permanent: true, createdAt: hours(-24 * 18)),
        Report(id: ReportID(raw: uuid(3, 5)), authorID: maya, kind: .steepEntrance, coordinate: at(39.9398, -75.0121),
               note: "Mall entrance off Haddonfield Rd scrapes. Use the Route 38 side.", confirmations: 4,
               permanent: true, createdAt: hours(-24 * 9)),
        Report(id: ReportID(raw: uuid(4, 5)), authorID: rosa, kind: .pothole, coordinate: at(39.9370, -74.9862),
               note: "Right lane, westbound 38 before Kings Hwy.", confirmations: 2,
               expiresAt: hours(24 * 80), createdAt: hours(-24 * 10)),
        Report(id: ReportID(raw: uuid(5, 5)), authorID: devon, kind: .police, coordinate: at(39.9101, -75.0012),
               confirmations: 1, expiresAt: hours(0.5), createdAt: hours(-0.25)),
        Report(id: ReportID(raw: uuid(6, 5)), authorID: nina, kind: .hazard, coordinate: at(39.8655, -75.0705),
               note: "Tire debris, left shoulder of 42 south.", confirmations: 2, expiresAt: hours(1.5),
               createdAt: hours(-0.5)),
        Report(id: ReportID(raw: uuid(7, 5)), authorID: marcus, kind: .closure, coordinate: at(39.9188, -75.0418),
               note: "Kings Hwy closed for water main work.", confirmations: 3, expiresAt: hours(20),
               createdAt: hours(-4)),
        Report(id: ReportID(raw: uuid(8, 5)), authorID: rosa, kind: .fuelE85, coordinate: at(39.9475, -74.9690),
               note: "E85 at pump 4.", confirmations: 5, permanent: true, createdAt: hours(-24 * 60)),
        Report(id: ReportID(raw: uuid(9, 5)), authorID: lena, kind: .roughRoad, coordinate: at(39.8340, -74.7900),
               note: "563 patchwork for about a mile north of Jenkins.", confirmations: 2,
               expiresAt: hours(24 * 60), createdAt: hours(-24 * 30)),
    ]

    public static let venueNotes: [VenueNote] = [
        VenueNote(authorID: jae, coordinate: at(39.9405, -75.0094), entrance: .moderate, lotSize: .large, lit: true,
                  note: "East entrance is flat. Avoid the ramp by the cinema."),
        VenueNote(authorID: maya, coordinate: at(39.8970, -75.0370), entrance: .flat, lotSize: .medium, lit: true),
    ]

    public static let roads: [Road] = [
        Road(id: RoadID(raw: uuid(1, 6)), authorID: lena, name: "Route 563 through Wharton",
             path: [at(39.8160, -74.7870), at(39.7700, -74.6770), at(39.7180, -74.5850), at(39.6730, -74.5300)],
             lengthMeters: 28_400, ratings: RoadRatingSummary(surface: 3.6, scenery: 4.7, traffic: 4.8, count: 14)),
        Road(id: RoadID(raw: uuid(2, 6)), authorID: rosa, name: "Atsion Road",
             path: [at(39.7426, -74.7258), at(39.7690, -74.7060), at(39.8010, -74.6830)],
             lengthMeters: 9_700, ratings: RoadRatingSummary(surface: 4.1, scenery: 4.2, traffic: 4.5, count: 6)),
    ]

    public static let spots: [Spot] = [
        Spot(spotterID: maya, catalogModelID: 501, year: 2022, make: "Porsche", model: "911 GT3",
             photoPath: "\(maya)/spots/1.jpg", city: "Cherry Hill"),
        Spot(spotterID: maya, catalogModelID: 502, year: 1991, make: "Acura", model: "NSX",
             photoPath: "\(maya)/spots/2.jpg", city: "Philadelphia"),
        Spot(spotterID: maya, catalogModelID: 503, year: 2015, make: "Lamborghini", model: "Huracán",
             photoPath: "\(maya)/spots/3.jpg", city: "Moorestown"),
    ]

    // MARK: Teams

    public static let jlc = TeamID(raw: uuid(1, 7))
    public static let sjs = TeamID(raw: uuid(2, 7))
    public static let dvm = TeamID(raw: uuid(3, 7))

    public static let teams: [Team] = [
        Team(id: jlc, ownerID: jae, name: "Jersey Low Club", tag: "JLC",
             about: "Lowered and slammed cars in South Jersey. We map every speed bump so you don't have to.",
             isPublic: true, inviteCode: "LOWJLC", memberCount: 4),
        Team(id: sjs, ownerID: rosa, name: "South Jersey Subies", tag: "SJS",
             about: "Monthly Pine Barrens cruise. All Subarus, and friends of Subarus.",
             isPublic: true, inviteCode: "SUBIE5", memberCount: 3),
        Team(id: dvm, ownerID: theo, name: "Delaware Valley Muscle", tag: "DVM",
             about: "Pre-1975 American muscle. Shows and parts swaps.", isPublic: false, inviteCode: "DVM396",
             memberCount: 2),
    ]

    public static let roles: [TeamRole] = teams.enumerated().flatMap { index, team in [
        TeamRole(id: TeamRoleID(raw: uuid(index * 10 + 1, 8)), teamID: team.id, name: "Owner",
                 colorHex: "#FFB224", rank: 0, permissions: .all),
        TeamRole(id: TeamRoleID(raw: uuid(index * 10 + 2, 8)), teamID: team.id, name: "Member",
                 rank: 1, permissions: []),
    ] }

    public static let members: [TeamMember] = [
        TeamMember(teamID: jlc, userID: jae), TeamMember(teamID: jlc, userID: maya),
        TeamMember(teamID: jlc, userID: devon), TeamMember(teamID: jlc, userID: lena),
        TeamMember(teamID: sjs, userID: rosa), TeamMember(teamID: sjs, userID: maya),
        TeamMember(teamID: sjs, userID: sam),
        TeamMember(teamID: dvm, userID: theo), TeamMember(teamID: dvm, userID: marcus),
    ]

    public static let channels: [Channel] = teams.enumerated().flatMap { index, team in [
        Channel(id: ChannelID(raw: uuid(index * 10 + 1, 9)), teamID: team.id, name: "general", kind: .text, sort: 0),
        Channel(id: ChannelID(raw: uuid(index * 10 + 2, 9)), teamID: team.id, name: "meets", kind: .text, sort: 1),
        Channel(id: ChannelID(raw: uuid(index * 10 + 3, 9)), teamID: team.id, name: "for-sale", kind: .text, sort: 2),
        Channel(id: ChannelID(raw: uuid(index * 10 + 4, 9)), teamID: team.id, name: "Garage", kind: .voice, sort: 3),
    ] }

    public static let dmWithDevon = MessageThread(id: ThreadID(raw: uuid(1, 10)), kind: .dm, aID: maya, bID: devon)

    public static let messages: [Message] = {
        let general = MessageTarget.channel(channels[0].id)
        let dm = MessageTarget.thread(dmWithDevon.id)
        let lines: [(MessageTarget, UserID, String, Double)] = [
            (general, jae, "Anyone know if the Cherry Hill lot still has the speed bumps by the cinema?", -26),
            (general, devon, "Still there. Come in off 38, it's flat.", -25.8),
            (general, lena, "Bringing the Miata Thursday if it stops raining.", -6),
            (general, maya, "I'll be there around 8:30 in the Mustang.", -5.5),
            (general, jae, "Rebuilt B16 is back in. First start went fine.", -1),
            (dm, devon, "You still want the style 68s for the winter setup?", -3),
            (dm, maya, "If they fit over the Brembos, yes.", -2.9),
            (dm, devon, "They do. Bring them Saturday.", -2.8),
        ]
        return lines.enumerated().map { index, line in
            Message(id: MessageID(raw: Int64(index + 1)), target: line.0, authorID: line.1, body: line.2,
                    createdAt: hours(line.3))
        }
    }()

    // MARK: Feed and Showdown

    public static let posts: [Post] = [
        Post(authorID: jae, carID: car(4), videoPath: "\(jae)/posts/b16-first-start.mp4",
             posterPath: "\(jae)/posts/b16-first-start.jpg", caption: "Rebuilt B16, first start",
             durationMs: 14_000, likeCount: 48, commentCount: 9, createdAt: hours(-1)),
        Post(authorID: nina, carID: car(7), videoPath: "\(nina)/posts/thunderbolt-lap.mp4",
             posterPath: "\(nina)/posts/thunderbolt-lap.jpg", caption: "Thunderbolt, clean lap in the rain",
             durationMs: 28_000, likeCount: 112, commentCount: 17, createdAt: hours(-20)),
        Post(authorID: theo, carID: car(6), videoPath: "\(theo)/posts/396-cold-start.mp4",
             posterPath: "\(theo)/posts/396-cold-start.jpg", caption: "396 cold start, December",
             durationMs: 21_000, likeCount: 230, commentCount: 41, createdAt: hours(-50)),
        Post(authorID: maya, carID: car(1), videoPath: "\(maya)/posts/coilovers-before-after.mp4",
             posterPath: "\(maya)/posts/coilovers-before-after.jpg", caption: "Coilovers, before and after",
             durationMs: 11_000, likeCount: 64, commentCount: 12, createdAt: hours(-24 * 4)),
    ]

    public static let showdownEntries: [ShowdownEntry] = [
        ShowdownEntry(carID: car(1), rating: 1264, wins: 31, losses: 22, showdownClass: .built),
        ShowdownEntry(carID: car(4), rating: 1318, wins: 44, losses: 25, showdownClass: .built),
        ShowdownEntry(carID: car(5), rating: 1201, wins: 12, losses: 12, showdownClass: .street),
        ShowdownEntry(carID: car(6), rating: 1402, wins: 70, losses: 21, showdownClass: .classic),
        ShowdownEntry(carID: car(7), rating: 1188, wins: 9, losses: 11, showdownClass: .street),
        ShowdownEntry(carID: car(9), rating: 1240, wins: 20, losses: 15, showdownClass: .street),
        ShowdownEntry(carID: car(10), rating: 1176, wins: 8, losses: 12, showdownClass: .street),
        ShowdownEntry(carID: car(11), rating: 1229, wins: 18, losses: 14, showdownClass: .built),
    ]

    // MARK: Market

    public static let listings: [Listing] = [
        Listing(id: ListingID(raw: uuid(1, 11)), sellerID: maya, kind: .part, title: "OEM 19 inch wheels, S550 Mustang GT",
                priceCents: 45_000, condition: .used,
                description: "Set of four with TPMS sensors. One has light curb rash. Pickup in Cherry Hill.",
                fits: Fitment(make: "Ford", model: "Mustang", yearFrom: 2015, yearTo: 2023), region: "Cherry Hill",
                photos: [ListingPhoto(path: "\(maya)/listings/wheels-1.jpg")], category: .wheelsTires),
        Listing(id: ListingID(raw: uuid(2, 11)), sellerID: jae, kind: .part, title: "Tein Flex Z coilovers, EK Civic",
                priceCents: 52_000, condition: .used, description: "About 20k miles on them. No leaks. Includes top hats.",
                fits: Fitment(make: "Honda", model: "Civic", yearFrom: 1996, yearTo: 2000), region: "Haddonfield",
                photos: [ListingPhoto(path: "\(jae)/listings/tein-1.jpg")], category: .suspension),
        Listing(id: ListingID(raw: uuid(3, 11)), sellerID: lena, kind: .car, title: "1995 Mazda MX-5 Miata, 98k miles",
                priceCents: 890_000, condition: .used,
                description: "Montego Blue, manual, new soft top in 2023. Timing belt done at 90k.",
                carID: car(9), region: "Moorestown", photos: [ListingPhoto(path: "\(lena)/listings/miata-1.jpg")]),
        Listing(id: ListingID(raw: uuid(4, 11)), sellerID: rosa, kind: .part, title: "Cobb Accessport V3, Subaru",
                priceCents: 35_000, condition: .used, description: "Unmarried and ready for a new car.",
                fits: Fitment(make: "Subaru", model: "WRX", yearFrom: 2015, yearTo: 2021), region: "Medford",
                photos: [ListingPhoto(path: "\(rosa)/listings/accessport-1.jpg")], category: .electronicsTuning),
        Listing(id: ListingID(raw: uuid(5, 11)), sellerID: theo, kind: .part, title: "Rally wheels, 15x7, set of four",
                priceCents: 60_000, condition: .used, description: "Correct for 1967 to 1969 Camaro. Caps included.",
                fits: Fitment(make: "Chevrolet", model: "Camaro", yearFrom: 1967, yearTo: 1969), region: "Collingswood",
                photos: [ListingPhoto(path: "\(theo)/listings/rally-1.jpg")], category: .wheelsTires),
        Listing(id: ListingID(raw: uuid(6, 11)), sellerID: jae, kind: .wanted, title: "Looking for a B18C1 head, any condition",
                priceCents: 40_000, condition: .used, description: "Cash ready. Can pick up within an hour of Haddonfield.",
                fits: Fitment(make: "Acura", model: "Integra", yearFrom: 1994, yearTo: 2001), region: "Haddonfield",
                category: .engine),
    ]

    // MARK: Progress

    public static let achievements: [Achievement] = [
        Achievement(userID: maya, key: "first_meet", earnedAt: hours(-24 * 25)),
        Achievement(userID: jae, key: "reports_10", earnedAt: hours(-24 * 5)),
    ]

    // MARK: Catalog

    public static let catalogMakes: [CatalogMake] = [
        "Acura", "BMW", "Chevrolet", "Dodge", "Ford", "Honda", "Hyundai", "Mazda", "Nissan", "Porsche",
        "Ram", "Subaru", "Toyota", "Volkswagen",
    ].enumerated().map { CatalogMake(id: Int64($0.offset + 1), name: $0.element) }

    public static let catalogModels: [CatalogModel] = [
        CatalogModel(id: 101, makeID: 5, name: "Mustang", yearFrom: 1965, yearTo: 2026),
        CatalogModel(id: 102, makeID: 2, name: "330i", yearFrom: 2001, yearTo: 2026),
        CatalogModel(id: 103, makeID: 13, name: "GR Supra", yearFrom: 2020, yearTo: 2026),
        CatalogModel(id: 104, makeID: 6, name: "Civic", yearFrom: 1973, yearTo: 2026),
        CatalogModel(id: 105, makeID: 12, name: "WRX", yearFrom: 2015, yearTo: 2026),
        CatalogModel(id: 106, makeID: 3, name: "Camaro", yearFrom: 1967, yearTo: 2024),
        CatalogModel(id: 107, makeID: 13, name: "GR86", yearFrom: 2022, yearTo: 2026),
        CatalogModel(id: 108, makeID: 11, name: "1500", yearFrom: 2011, yearTo: 2026),
        CatalogModel(id: 109, makeID: 8, name: "MX-5 Miata", yearFrom: 1990, yearTo: 2026),
        CatalogModel(id: 110, makeID: 14, name: "Golf GTI", yearFrom: 1985, yearTo: 2026),
        CatalogModel(id: 111, makeID: 9, name: "350Z", yearFrom: 2003, yearTo: 2009),
        CatalogModel(id: 112, makeID: 12, name: "BRZ", yearFrom: 2013, yearTo: 2026),
    ]

    public static let catalogVariants: [CatalogVariant] = [
        CatalogVariant(id: 1001, modelID: 101, make: "Ford", model: "Mustang", year: 2019, trim: "GT",
                       engine: "5.0 L V8", displacementL: 5.0, cylinders: 8, aspiration: .natural, drive: .rwd,
                       transmission: "6-speed manual", hp: 460, torqueLbFt: 420, weightLb: 3705, redline: 7500),
        CatalogVariant(id: 1013, modelID: 101, make: "Ford", model: "Mustang", year: 2019, trim: "EcoBoost",
                       engine: "2.3 L I4", displacementL: 2.3, cylinders: 4, aspiration: .turbo, drive: .rwd,
                       transmission: "10-speed automatic", hp: 310, torqueLbFt: 350, weightLb: 3532, redline: 6500),
        CatalogVariant(id: 1002, modelID: 102, make: "BMW", model: "330i", year: 2004, engine: "3.0 L I6",
                       displacementL: 3.0, cylinders: 6, aspiration: .natural, drive: .rwd,
                       transmission: "5-speed manual", hp: 225, torqueLbFt: 214, weightLb: 3285, redline: 6500),
        CatalogVariant(id: 1003, modelID: 103, make: "Toyota", model: "GR Supra", year: 2020, trim: "3.0",
                       engine: "3.0 L I6", displacementL: 3.0, cylinders: 6, aspiration: .turbo, drive: .rwd,
                       transmission: "8-speed automatic", hp: 335, torqueLbFt: 365, weightLb: 3397, redline: 6500),
        CatalogVariant(id: 1004, modelID: 104, make: "Honda", model: "Civic", year: 1999, trim: "Si",
                       engine: "1.6 L I4", displacementL: 1.6, cylinders: 4, aspiration: .natural, drive: .fwd,
                       transmission: "5-speed manual", hp: 160, torqueLbFt: 111, weightLb: 2557, redline: 8200),
        CatalogVariant(id: 1005, modelID: 105, make: "Subaru", model: "WRX", year: 2015, trim: "Premium",
                       engine: "2.0 L flat-4", displacementL: 2.0, cylinders: 4, aspiration: .turbo, drive: .awd,
                       transmission: "6-speed manual", hp: 268, torqueLbFt: 258, weightLb: 3267, redline: 6700),
        CatalogVariant(id: 1006, modelID: 106, make: "Chevrolet", model: "Camaro", year: 1969, trim: "SS 396",
                       engine: "6.5 L V8", displacementL: 6.5, cylinders: 8, aspiration: .natural, drive: .rwd,
                       transmission: "4-speed manual", hp: 325, torqueLbFt: 410, weightLb: 3500, redline: 5800),
        CatalogVariant(id: 1007, modelID: 107, make: "Toyota", model: "GR86", year: 2022, trim: "Premium",
                       engine: "2.4 L flat-4", displacementL: 2.4, cylinders: 4, aspiration: .natural, drive: .rwd,
                       transmission: "6-speed manual", hp: 228, torqueLbFt: 184, weightLb: 2838, redline: 7500),
        CatalogVariant(id: 1008, modelID: 108, make: "Ram", model: "1500", year: 2021, trim: "TRX",
                       engine: "6.2 L V8", displacementL: 6.2, cylinders: 8, aspiration: .supercharged, drive: .fourWD,
                       transmission: "8-speed automatic", hp: 702, torqueLbFt: 650, weightLb: 6350, redline: 6200),
        CatalogVariant(id: 1009, modelID: 109, make: "Mazda", model: "MX-5 Miata", year: 1995, engine: "1.8 L I4",
                       displacementL: 1.8, cylinders: 4, aspiration: .natural, drive: .rwd,
                       transmission: "5-speed manual", hp: 128, torqueLbFt: 110, weightLb: 2293, redline: 7000),
        CatalogVariant(id: 1010, modelID: 110, make: "Volkswagen", model: "Golf GTI", year: 2018, trim: "SE",
                       engine: "2.0 L I4", displacementL: 2.0, cylinders: 4, aspiration: .turbo, drive: .fwd,
                       transmission: "6-speed manual", hp: 220, torqueLbFt: 258, weightLb: 3086, redline: 6500),
        CatalogVariant(id: 1011, modelID: 111, make: "Nissan", model: "350Z", year: 2005, trim: "Track",
                       engine: "3.5 L V6", displacementL: 3.5, cylinders: 6, aspiration: .natural, drive: .rwd,
                       transmission: "6-speed manual", hp: 287, torqueLbFt: 274, weightLb: 3325, redline: 6600),
        CatalogVariant(id: 1012, modelID: 104, make: "Honda", model: "Civic", year: 2017, trim: "Type R",
                       engine: "2.0 L I4", displacementL: 2.0, cylinders: 4, aspiration: .turbo, drive: .fwd,
                       transmission: "6-speed manual", hp: 306, torqueLbFt: 295, weightLb: 3117, redline: 7000),
        CatalogVariant(id: 1014, modelID: 112, make: "Subaru", model: "BRZ", year: 2022, trim: "Limited",
                       engine: "2.4 L flat-4", displacementL: 2.4, cylinders: 4, aspiration: .natural, drive: .rwd,
                       transmission: "6-speed manual", hp: 228, torqueLbFt: 184, weightLb: 2815, redline: 7500),
    ]
}
