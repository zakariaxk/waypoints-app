import Foundation

/// In-memory implementation of every `Core` repository, the auth service, media, gateway,
/// and safety, seeded from `PreviewSeed`. Used by SwiftUI previews and, until each owner
/// replaces it, by the infrastructure factories in the running app.
public actor PreviewStore {
    /// Shared instance the app uses before live implementations exist. Starts signed out.
    public static let shared = PreviewStore(signedIn: false)

    var session: AuthSession?
    var profiles: [UserID: Profile]
    var privacy: [UserID: PrivacySettings]
    var deviceTokens: [UserID: Set<String>] = [:]
    var cars: [CarID: Car]
    var carPhotos: [CarPhoto]
    var buildEntries: [BuildEntry]
    var friendships: [Friendship]
    var blocks: Set<Pair> = []
    var reports: [ReportID: Report]
    var reportVotes: [Pair: Bool] = [:]
    var meets: [MeetID: Meet]
    var rsvps: [MeetRSVP]
    var venueNotes: [VenueNote]
    var roads: [RoadID: Road]
    var roadRatings: [Pair: RoadRating] = [:]
    var spots: [Spot]
    var teams: [TeamID: Team]
    var roles: [TeamRole]
    var members: [TeamMember]
    var channels: [ChannelID: Channel]
    var threads: [ThreadID: MessageThread]
    var messages: [Message]
    var readMarkers: [MessageTarget: MessageID] = [:]
    var posts: [PostID: Post]
    var likes: Set<Pair> = []
    var comments: [PostComment] = []
    var follows: Set<Pair> = []
    var showdown: [CarID: ShowdownEntry]
    var showdownVotes: Set<[UUID]> = []
    var listings: [ListingID: Listing]
    var saves: Set<Pair> = []
    var achievements: [Achievement]
    var raceResults: [RaceResult] = []
    var termsAccepted = true
    var notificationPrefs = NotificationPrefs()

    var sessionBroadcast = Broadcast<AuthSession?>()
    var profileBroadcast = Broadcast<Profile>()
    var carBroadcasts: [UserID: Broadcast<[Car]>] = [:]
    var friendBroadcast = Broadcast<[Friend]>()
    var blockedBroadcast = Broadcast<Set<UserID>>()
    var messageBroadcasts: [MessageTarget: Broadcast<Message>] = [:]
    var unreadBroadcast = Broadcast<Int>()

    /// Two ids stored as an unordered or ordered pair key.
    struct Pair: Hashable, Sendable {
        let a: UUID, b: UUID
        init(_ a: UUID, _ b: UUID) { self.a = a; self.b = b }
    }

    public init(signedIn: Bool = true) {
        let seed = PreviewSeed.self
        session = signedIn ? PreviewStore.makeSession(for: seed.me, needsOnboarding: false) : nil
        profiles = Dictionary(uniqueKeysWithValues: seed.profiles.map { ($0.userID, $0) })
        privacy = seed.privacy
        cars = Dictionary(uniqueKeysWithValues: seed.cars.map { ($0.id, $0) })
        carPhotos = seed.carPhotos
        buildEntries = seed.buildEntries
        friendships = seed.friendships
        reports = Dictionary(uniqueKeysWithValues: seed.reports.map { ($0.id, $0) })
        meets = Dictionary(uniqueKeysWithValues: seed.meets.map { ($0.id, $0) })
        rsvps = seed.rsvps
        venueNotes = seed.venueNotes
        roads = Dictionary(uniqueKeysWithValues: seed.roads.map { ($0.id, $0) })
        spots = seed.spots
        teams = Dictionary(uniqueKeysWithValues: seed.teams.map { ($0.id, $0) })
        roles = seed.roles
        members = seed.members
        channels = Dictionary(uniqueKeysWithValues: seed.channels.map { ($0.id, $0) })
        threads = [seed.dmWithDevon.id: seed.dmWithDevon]
        messages = seed.messages
        posts = Dictionary(uniqueKeysWithValues: seed.posts.map { ($0.id, $0) })
        showdown = Dictionary(uniqueKeysWithValues: seed.showdownEntries.map { ($0.carID, $0) })
        listings = Dictionary(uniqueKeysWithValues: seed.listings.map { ($0.id, $0) })
        achievements = seed.achievements
    }

    static func makeSession(for user: UserID, needsOnboarding: Bool) -> AuthSession {
        AuthSession(userID: user, email: "maya@example.com", accessToken: "preview-token",
                    expiresAt: .now.addingTimeInterval(3600), needsOnboarding: needsOnboarding)
    }

    // MARK: Shared helpers

    func me() throws -> UserID {
        guard let session else { throw WaypointsError.notSignedIn }
        return session.userID
    }

    func isBlockedEitherWay(_ a: UserID, _ b: UserID) -> Bool {
        blocks.contains(Pair(a.raw, b.raw)) || blocks.contains(Pair(b.raw, a.raw))
    }

    func visible(_ author: UserID) -> Bool {
        guard let me = session?.userID else { return true }
        return !isBlockedEitherWay(me, author)
    }

    func friendList() -> [Friend] {
        guard let me = session?.userID else { return [] }
        return friendships
            .filter { $0.status == .accepted && ($0.requesterID == me || $0.addresseeID == me) }
            .compactMap { f -> Friend? in
                let other = f.other(than: me)
                guard let profile = profiles[other], !isBlockedEitherWay(me, other) else { return nil }
                return Friend(profile: profile, primaryCar: profile.primaryCarID.flatMap { cars[$0] }, since: f.createdAt)
            }
            .sorted { $0.profile.displayName < $1.profile.displayName }
    }

    func carList(of owner: UserID) -> [Car] {
        cars.values.filter { $0.ownerID == owner }.sorted { ($0.sort, $0.createdAt) < ($1.sort, $1.createdAt) }
    }

    func unreadTotal() -> Int {
        guard let me = session?.userID else { return 0 }
        return messages.filter { message in
            guard message.authorID != me, message.deletedAt == nil else { return false }
            return message.id > (readMarkers[message.target] ?? MessageID(raw: 0)) && canRead(message.target, as: me)
        }.count
    }

    func canRead(_ target: MessageTarget, as user: UserID) -> Bool {
        switch target {
        case .channel(let id):
            guard let channel = channels[id] else { return false }
            return members.contains { $0.teamID == channel.teamID && $0.userID == user }
        case .thread(let id):
            guard let thread = threads[id] else { return false }
            return thread.aID == user || thread.bID == user
        }
    }

    func profileChanged(_ profile: Profile) {
        profiles[profile.userID] = profile
        if profile.userID == session?.userID { profileBroadcast.send(profile) }
    }

    func carsChanged(of owner: UserID) {
        carBroadcasts[owner]?.send(carList(of: owner))
    }

    func setSession(_ newValue: AuthSession?) {
        session = newValue
        sessionBroadcast.send(newValue)
        friendBroadcast.send(friendList())
        unreadBroadcast.send(unreadTotal())
    }
}
