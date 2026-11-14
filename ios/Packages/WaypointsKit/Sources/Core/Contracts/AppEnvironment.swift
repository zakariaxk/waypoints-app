import Foundation

/// Environment handed to every feature (plan section 4.3).
public struct AppEnvironment: Sendable {
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
    public let realtime: any RealtimeService
    public let location: any LocationService
    public let gateway: any GatewayService
    public let catalog: any VehicleCatalogService
    public let safety: any SafetyService
    public let router: any Router
    public let activity: any ActivityRepository

    public init(
        auth: any AuthService, profiles: any ProfileRepository, garage: any GarageRepository,
        friends: any FriendRepository, meets: any MeetRepository, reports: any ReportRepository,
        teams: any TeamRepository, messages: any MessageRepository, posts: any PostRepository,
        showdown: any ShowdownRepository, market: any MarketRepository, spots: any SpotRepository,
        roads: any RoadRepository, progress: any ProgressRepository, media: any MediaStore,
        realtime: any RealtimeService, location: any LocationService, gateway: any GatewayService,
        catalog: any VehicleCatalogService, safety: any SafetyService, router: any Router,
        activity: any ActivityRepository = PreviewActivity.shared
    ) {
        self.auth = auth; self.profiles = profiles; self.garage = garage; self.friends = friends
        self.meets = meets; self.reports = reports; self.teams = teams; self.messages = messages
        self.posts = posts; self.showdown = showdown; self.market = market; self.spots = spots
        self.roads = roads; self.progress = progress; self.media = media; self.realtime = realtime
        self.location = location; self.gateway = gateway; self.catalog = catalog; self.safety = safety
        self.router = router
        self.activity = activity
    }
}
