import Foundation

/// Navigation between features without importing each other (plan 4.3).
public enum Route: Hashable, Sendable {
    case profile(UserID), car(CarID), meet(MeetID), team(TeamID), channel(ChannelID), voice(ChannelID), thread(ThreadID)
    case listing(ListingID), post(PostID), report(ReportID), vehiclePicker(forCar: CarID?)
    case modSim(CarID), race(CarID), reportContent(ContentRef), settings, settingsPrivacy, createMeet(Coordinate?), createReport(Coordinate), spotCar
    case navigate(to: Coordinate, name: String?)
    case joinTeam(code: String), joinConvoy(code: String)     // invite deep links (section 10.10, X3)
    case convoyVoice(ConvoyID)
    case activity     // NTF-6, the Activity list (W7-2)
    case askForHelp(Coordinate), help(HelpRequestID)           // PRD HELP (ReportsFeature)

    /// The case without its payload, used to key route handlers in `FeatureRegistry`.
    public enum Kind: Hashable, Sendable, CaseIterable {
        case profile, car, meet, team, channel, voice, thread, listing, post, report, vehiclePicker
        case modSim, race, reportContent, settings, settingsPrivacy, createMeet, createReport, spotCar, navigate, joinTeam, joinConvoy
        case convoyVoice
        case activity
        case askForHelp, help
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
        case .reportContent: .reportContent
        case .settings: .settings
        case .settingsPrivacy: .settingsPrivacy
        case .createMeet: .createMeet
        case .createReport: .createReport
        case .spotCar: .spotCar
        case .navigate: .navigate
        case .joinTeam: .joinTeam
        case .joinConvoy: .joinConvoy
        case .convoyVoice: .convoyVoice
        case .activity: .activity
        case .askForHelp: .askForHelp
        case .help: .help
        }
    }
}

public protocol Router: Sendable { @MainActor func open(_ route: Route) }
