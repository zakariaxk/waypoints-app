import Foundation

/// Navigation between features without importing each other (plan 4.3).
public enum Route: Hashable, Sendable {
    case profile(UserID), car(CarID), meet(MeetID), team(TeamID), channel(ChannelID), thread(ThreadID)
    case listing(ListingID), post(PostID), report(ReportID), vehiclePicker(forCar: CarID?)
    case modSim(CarID), race(CarID), reportContent(ContentRef), settingsPrivacy, createMeet(Coordinate?)
    case navigate(to: Coordinate, name: String?)
    case joinTeam(code: String), joinConvoy(code: String)     // invite deep links (section 10.10, X3)

    /// The case without its payload, used to key route handlers in `FeatureRegistry`.
    public enum Kind: Hashable, Sendable, CaseIterable {
        case profile, car, meet, team, channel, thread, listing, post, report, vehiclePicker
        case modSim, race, reportContent, settingsPrivacy, createMeet, navigate, joinTeam, joinConvoy
    }

    public var kind: Kind {
        switch self {
        case .profile: .profile
        case .car: .car
        case .meet: .meet
        case .team: .team
        case .channel: .channel
        case .thread: .thread
        case .listing: .listing
        case .post: .post
        case .report: .report
        case .vehiclePicker: .vehiclePicker
        case .modSim: .modSim
        case .race: .race
        case .reportContent: .reportContent
        case .settingsPrivacy: .settingsPrivacy
        case .createMeet: .createMeet
        case .navigate: .navigate
        case .joinTeam: .joinTeam
        case .joinConvoy: .joinConvoy
        }
    }
}

public protocol Router: Sendable { @MainActor func open(_ route: Route) }
