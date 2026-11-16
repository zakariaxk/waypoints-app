import Foundation

/// Navigation between features without importing each other (plan 4.3).
public enum Route: Hashable, Sendable {
    case profile(UserID), car(CarID), meet(MeetID), team(TeamID), channel(ChannelID), voice(ChannelID)
    /// MKT-2: `draft` prefills the composer (Message seller); nil opens the thread as before.
    case thread(ThreadID, draft: String? = nil)
    case listing(ListingID), post(PostID), report(ReportID), vehiclePicker(forCar: CarID?)
    case modSim(CarID), race(CarID), drive(CarID), shop(CarID), reportContent(ContentRef), settings, settingsPrivacy, createMeet(Coordinate?), createReport(Coordinate), spotCar
    case navigate(to: Coordinate, name: String?)
    /// ROAD-6: a loop's roads joined end to end; navigation routes through it in order.
    case navigatePath(path: [Coordinate], name: String?)
    case joinTeam(code: String), joinConvoy(code: String)     // invite deep links (section 10.10, X3)
    case convoyVoice(ConvoyID)
    case activity     // NTF-6, the Activity list (W7-2)
    case askForHelp(Coordinate), help(HelpRequestID)           // PRD HELP (ReportsFeature)
    case loop(LoopID)     // ROAD-6 (RoadsFeature)
    case road(RoadID)     // FEED-12 (RoadsFeature)
    /// FEED-12: opens the post composer with a road pre-attached (FeedFeature).
    case compose(road: RoadID)
    case guides, guide(GuideID)     // KNW-2/3 (GuidesFeature)

    /// The case without its payload, used to key route handlers in `FeatureRegistry`.
    public enum Kind: Hashable, Sendable, CaseIterable {
        case profile, car, meet, team, channel, voice, thread, listing, post, report, vehiclePicker
        case modSim, race, drive, shop, reportContent, settings, settingsPrivacy, createMeet, createReport, spotCar, navigate, navigatePath, joinTeam, joinConvoy
        case convoyVoice
        case activity
        case askForHelp, help
        case loop
        case road, compose
        case guides, guide
    }

    public var kind: Kind {
        switch self {
        case .profile: .profile
        case .car: .car
        case .meet: .meet
        case .team: .team
        case .channel: .channel
        case .voice: .voice
        case .thread: .thread
        case .listing: .listing
        case .post: .post
        case .report: .report
        case .vehiclePicker: .vehiclePicker
        case .modSim: .modSim
        case .race: .race
        case .drive: .drive
        case .shop: .shop
        case .reportContent: .reportContent
        case .settings: .settings
        case .settingsPrivacy: .settingsPrivacy
        case .createMeet: .createMeet
        case .createReport: .createReport
        case .spotCar: .spotCar
        case .navigate: .navigate
        case .navigatePath: .navigatePath
        case .joinTeam: .joinTeam
        case .joinConvoy: .joinConvoy
        case .convoyVoice: .convoyVoice
        case .activity: .activity
        case .askForHelp: .askForHelp
        case .help: .help
        case .loop: .loop
        case .road: .road
        case .compose: .compose
        case .guides: .guides
        case .guide: .guide
        }
    }
}

public protocol Router: Sendable { @MainActor func open(_ route: Route) }
