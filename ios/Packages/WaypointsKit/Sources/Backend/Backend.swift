import Core

/// Supabase-backed implementations of the `Core` repositories, auth, and media.
public enum Backend {
    public struct Services: Sendable {
        public let auth: any AuthService
        public let profiles: any ProfileRepository
        public let garage: any GarageRepository
        public let friends: any FriendRepository
        public let meets: any MeetRepository
        public let reports: any ReportRepository
        public let teams: any TeamRepository
        public let messages: any MessageRepository
        public let posts: any PostRepository
        public let showdown: any ShowdownRepository
        public let market: any MarketRepository
        public let spots: any SpotRepository
        public let roads: any RoadRepository
        public let progress: any ProgressRepository
        public let media: any MediaStore
        public let activity: any ActivityRepository

        public init(auth: any AuthService, profiles: any ProfileRepository, garage: any GarageRepository,
                    friends: any FriendRepository, meets: any MeetRepository, reports: any ReportRepository,
                    teams: any TeamRepository, messages: any MessageRepository, posts: any PostRepository,
                    showdown: any ShowdownRepository, market: any MarketRepository, spots: any SpotRepository,
                    roads: any RoadRepository, progress: any ProgressRepository, media: any MediaStore,
                    activity: any ActivityRepository) {
            self.auth = auth; self.profiles = profiles; self.garage = garage; self.friends = friends
            self.meets = meets; self.reports = reports; self.teams = teams; self.messages = messages
            self.posts = posts; self.showdown = showdown; self.market = market; self.spots = spots
            self.roads = roads; self.progress = progress; self.media = media
            self.activity = activity
        }
    }

    /// Live Supabase implementations. With no anon key configured (a fresh clone without
    /// `Config.xcconfig` values) it falls back to the in-memory preview store so the app runs.
    public static func makeLive(config: AppConfig) -> Services {
        guard !config.supabaseAnonKey.isEmpty else { return makePreview() }
        let ctx = BackendContext(config: config)
        let profiles = LiveProfiles(ctx: ctx, changes: Fanout())
        let garage = LiveGarage(ctx: ctx, changes: FanoutTable())
        return Services(
            auth: LiveAuth(ctx: ctx),
            profiles: profiles,
            garage: garage,
            friends: LiveFriends(ctx: ctx, changes: Fanout()),
            meets: LiveMeets(ctx: ctx),
            reports: LiveReports(ctx: ctx),
            teams: LiveTeams(ctx: ctx),
            messages: LiveMessages(ctx: ctx, unread: Fanout()),
            posts: LivePosts(ctx: ctx),
            showdown: LiveShowdown(ctx: ctx, garage: garage, profiles: profiles),
            market: LiveMarket(ctx: ctx),
            spots: LiveSpots(ctx: ctx),
            roads: LiveRoads(ctx: ctx),
            progress: LiveProgress(ctx: ctx),
            media: LiveMedia(ctx: ctx),
            activity: LiveActivity(ctx: ctx, unread: Fanout())
        )
    }

    #if DEBUG
    /// Signs in with email and password (the seed users' development password). Debug builds
    /// only, for the `-wp-login` launch argument; throws unless `auth` is the live service.
    public static func debugSignIn(_ auth: any AuthService, email: String, password: String) async throws -> AuthSession {
        guard let live = auth as? LiveAuth else { throw WaypointsError.invalid("auth is not the live service") }
        return try await live.debugSignIn(email: email, password: password)
    }
    #endif

    /// The in-memory store from `Core`, signed out at launch.
    public static func makePreview() -> Services {
        let store = PreviewStore.shared
        return Services(auth: store, profiles: store, garage: store, friends: store, meets: store, reports: store,
                        teams: store, messages: store, posts: store, showdown: store, market: store, spots: store,
                        roads: store, progress: store, media: store,
                        activity: PreviewActivity.shared)
    }
}
