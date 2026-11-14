#if DEBUG
import Core
import Foundation

/// `waypoints://debug/<screen>` (PRD 7.1), debug builds only. Opens any plan section 10 screen
/// without tapping, for `make shot`:
///
///     make shot NAME=g6 ARGS="-wp-preview -wp-open waypoints://debug/modsim"
///
/// A name a feature registered with `FeatureRegistry.registerDebugScreen` wins (that is how a
/// feature exposes internal screens and states, for example `feed/empty`). Otherwise the name
/// maps to a tab or to a `Route` filled with the first matching item from the environment's
/// repositories, so the same link works on preview data and on the local seed.
/// `waypoints://debug/list` prints every name to the console.
@MainActor
enum DebugLinks {
    static func handles(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "waypoints" && url.host()?.lowercased() == "debug"
    }

    /// Built-in names, by plan section 10 screen.
    static let names: [(name: String, screen: String)] = [
        ("map", "M1 Map"), ("search", "M2 Search"), ("route", "M3 Route preview"), ("route-preview", "M3 Route preview"),
        ("nav", "M4 Navigation"), ("report", "M5 Report"), ("report-detail", "M6 Report detail"),
        ("convoy", "M9 Convoy"), ("help", "Help request"), ("spot", "M12 Spot"), ("activity", "Activity"),
        ("meet", "E2 Meet"), ("meet-start", "E1 Start a meet"),
        ("feed", "F1 Feed"), ("post", "F1 Post"), ("comments", "F2 Comments"), ("showdown", "F4 Showdown"), ("rankings", "F5 Rankings"),
        ("market", "K1 Browse"), ("listing", "K2 Listing"), ("market-listing", "K2 Listing"),
        ("teams", "T1 Teams"), ("team", "T5 Team"), ("channel", "T2 Channel"), ("team-channel", "T2 Channel"),
        ("voice", "T3 Voice"), ("thread", "T7 Direct thread"),
        ("garage", "G1 Garage"), ("profile", "G2 Profile"), ("car", "G3 Car"), ("garage-car", "G3 Car"),
        ("picker", "G4 Vehicle picker"), ("modsim", "G6 Mod simulator"), ("mod-simulator", "G6 Mod simulator"),
        ("strip", "G7 Strip lobby"), ("slip", "G9 Time slip"),
        ("settings", "S1 Settings"), ("settings-privacy", "S2 Privacy and location"),
        ("settings-notifications", "S3 Notifications"), ("settings-blocked", "S4 Blocked people"),
        ("settings-account", "S5 Account"), ("settings-about", "S6 About"),
        ("report-sheet", "X1 Report or block"), ("terms", "X2 Terms gate"),
    ]

    private enum Target {
        case tab(AppTab)
        case route(Route)
    }

    static func open(_ url: URL, shell: ShellModel) async {
        let name = url.pathComponents.filter { $0 != "/" }.joined(separator: "/").lowercased()
        let router = shell.router
        if name == "list" || name.isEmpty {
            let registered = shell.registry.debugScreens.keys.sorted()
            print("debug links: " + (names.map { "\($0.name) (\($0.screen))" } + registered).joined(separator: ", "))
            return
        }
        if shell.registry.debugScreens[name] != nil {
            router.debugScreen = PresentedDebugScreen(name: name)
            return
        }
        guard let target = await resolve(name, env: shell.environment) else {
            print("debug link: nothing to open for \(name) (unknown name, or no seed item for it)")
            return
        }
        router.sheet = nil
        router.fullScreen = nil
        router.debugScreen = nil
        switch target {
        case .tab(let tab):
            router.paths[tab] = []
            router.selectedTab = tab
        case .route(let route):
            router.open(route)
        }
    }

    // MARK: Resolution

    /// Covers the preview seed (Cherry Hill) and the local seed (Philadelphia and South Jersey).
    private static let region = MapRegion(minLatitude: 39.3, minLongitude: -75.4, maxLatitude: 40.2, maxLongitude: -74.4)
    private static let here = Coordinate(latitude: 39.9387, longitude: -75.0230)

    private static func resolve(_ name: String, env: AppEnvironment) async -> Target? {
        switch name {
        case "map", "search": return .tab(.map)
        case "feed", "showdown", "rankings": return .tab(.feed)
        case "market", "market-new", "market-yours": return .tab(.market)
        case "teams": return .tab(.teams)
        case "garage": return .tab(.garage)

        case "route", "route-preview", "nav", "navigation":
            let meet = await firstMeet(env)
            return .route(.navigate(to: meet?.coordinate ?? here, name: meet?.placeName ?? "Cherry Hill Mall"))
        case "report", "report-new": return .route(.createReport(here))
        case "report-detail":
            return await firstReport(env).map { .route(.report($0)) }
        case "convoy": return .route(.joinConvoy(code: "R70RUN"))
        case "help": return .route(.askForHelp(here))
        case "spot": return .route(.spotCar)
        case "activity": return .route(.activity)

        case "meet": return await firstMeet(env).map { .route(.meet($0.id)) }
        case "meet-start", "meet-create": return .route(.createMeet(here))

        case "post", "comments": return await firstPost(env).map { .route(.post($0)) }
        case "report-sheet", "report-content":
            return await firstPost(env).map { .route(.reportContent(ContentRef(kind: .post, id: $0.description))) }

        case "listing", "market-listing": return await firstListing(env).map { .route(.listing($0)) }

        case "team": return await firstTeam(env).map { .route(.team($0)) }
        case "channel", "team-channel": return await firstChannel(env, kind: .text).map { .route(.channel($0)) }
        case "voice": return await firstChannel(env, kind: .voice).map { .route(.voice($0)) }
        case "thread", "dm": return await firstThread(env).map { .route(.thread($0)) }

        case "profile": return await firstFriend(env).map { .route(.profile($0)) }
        case "car", "garage-car": return await myCar(env).map { .route(.car($0)) }
        case "picker": return .route(.vehiclePicker(forCar: nil))
        case "modsim", "mod-simulator": return await myCar(env).map { .route(.modSim($0)) }
        case "strip", "race", "run", "slip": return await myCar(env).map { .route(.race($0)) }

        case "settings", "settings-notifications", "settings-blocked", "settings-account", "settings-about":
            return .route(.settings)
        case "settings-privacy", "privacy": return .route(.settingsPrivacy)
        default: return nil
        }
    }

    private static func me(_ env: AppEnvironment) async -> UserID? { await env.auth.currentSession()?.userID }

    private static func myCar(_ env: AppEnvironment) async -> CarID? {
        guard let me = await me(env) else { return nil }
        return try? await env.garage.cars(of: me).first?.id
    }

    private static func firstMeet(_ env: AppEnvironment) async -> Meet? {
        (try? await env.meets.meets(in: region))?.sorted { $0.startsAt < $1.startsAt }.first { $0.endsAt > .now }
    }

    private static func firstReport(_ env: AppEnvironment) async -> ReportID? {
        (try? await env.reports.reports(in: region))?.first?.id
    }

    private static func firstPost(_ env: AppEnvironment) async -> PostID? {
        (try? await env.posts.feed(after: nil, limit: 1))?.items.first?.id
    }

    private static func firstListing(_ env: AppEnvironment) async -> ListingID? {
        (try? await env.market.listings(ListingFilter(), after: nil, limit: 1))?.items.first?.id
    }

    private static func firstTeam(_ env: AppEnvironment) async -> TeamID? {
        (try? await env.teams.myTeams())?.first?.id
    }

    private static func firstChannel(_ env: AppEnvironment, kind: ChannelKind) async -> ChannelID? {
        guard let team = await firstTeam(env), let channels = try? await env.teams.channels(of: team) else { return nil }
        return (channels.first { $0.kind == kind } ?? channels.first)?.id
    }

    private static func firstThread(_ env: AppEnvironment) async -> ThreadID? {
        (try? await env.messages.threads())?.first?.id
    }

    private static func firstFriend(_ env: AppEnvironment) async -> UserID? {
        (try? await env.friends.friends())?.first?.id
    }
}
#endif
