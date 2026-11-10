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

        public init(auth: any AuthService, profiles: any ProfileRepository, garage: any GarageRepository,
                    friends: any FriendRepository, meets: any MeetRepository, reports: any ReportRepository,
                    teams: any TeamRepository, messages: any MessageRepository, posts: any PostRepository,
                    showdown: any ShowdownRepository, market: any MarketRepository, spots: any SpotRepository,
                    roads: any RoadRepository, progress: any ProgressRepository, media: any MediaStore) {
            self.auth = auth; self.profiles = profiles; self.garage = garage; self.friends = friends
            self.meets = meets; self.reports = reports; self.teams = teams; self.messages = messages
            self.posts = posts; self.showdown = showdown; self.market = market; self.spots = spots
            self.roads = roads; self.progress = progress; self.media = media
        }
    }

    /// Live Supabase implementations. With no anon key configured (a fresh clone without
    /// `Config.xcconfig` values) it falls back to the in-memory preview store so the app runs.
    public static func makeLive(config: AppConfig) -> Services {
        guard !config.supabaseAnonKey.isEmpty else { return makePreview() }
        let ctx = BackendContext(config: config)
        let store = PreviewStore.shared
        return Services(
            auth: LiveAuth(ctx: ctx),
            profiles: LiveProfiles(ctx: ctx, changes: Fanout()),
            garage: LiveGarage(ctx: ctx, changes: FanoutTable()),
            friends: LiveFriends(ctx: ctx, changes: Fanout()),
            meets: LiveMeets(ctx: ctx),
            reports: LiveReports(ctx: ctx),
            teams: store, messages: store, posts: store, showdown: store, market: store,
            spots: LiveSpots(ctx: ctx),
            roads: LiveRoads(ctx: ctx),
            progress: store,
            media: LiveMedia(ctx: ctx)
        )
    }

    /// The in-memory store from `Core`, signed out at launch.
    public static func makePreview() -> Services {
        let store = PreviewStore.shared
        return Services(auth: store, profiles: store, garage: store, friends: store, meets: store, reports: store,
                        teams: store, messages: store, posts: store, showdown: store, market: store, spots: store,
                        roads: store, progress: store, media: store)
    }
}
