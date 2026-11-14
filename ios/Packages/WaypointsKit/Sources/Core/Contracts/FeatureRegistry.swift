import SwiftUI

/// The five tabs of section 10.1, in order. A tab is shown only if a feature registered it.
public enum AppTab: Int, Hashable, Sendable, CaseIterable, Comparable {
    case map = 1, feed, market, teams, garage

    public var title: String {
        switch self {
        case .map: "Map"
        case .feed: "Feed"
        case .market: "Market"
        case .teams: "Teams"
        case .garage: "Garage"
        }
    }

    public var symbol: String {
        switch self {
        case .map: "map"
        case .feed: "play.rectangle"
        case .market: "tag"
        case .teams: "person.3"
        case .garage: "car.side"
        }
    }

    public static func < (lhs: AppTab, rhs: AppTab) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How the shell shows a route's view.
public enum RoutePresentation: Hashable, Sendable {
    /// Pushed onto the navigation stack of `tab`, or of the current tab when `nil`.
    case push(tab: AppTab?)
    case sheet
    case fullScreen
}

public struct TabRegistration {
    public let tab: AppTab
    public let root: @MainActor () -> AnyView
    /// Called when the user taps the tab while it is already selected and at its root
    /// (Map uses it to recenter, section 10.1).
    public let onReselect: (@MainActor () -> Void)?
    /// Count shown on the tab (Teams unread, section 10.1). Read during view updates, so a value
    /// from an `@Observable` model refreshes the badge. Zero hides it.
    public let badge: (@MainActor () -> Int)?
}

public struct RouteRegistration {
    public let kind: Route.Kind
    public let presentation: RoutePresentation
    public let view: @MainActor (Route) -> AnyView?
}

/// Everything features plug into the app (plan 4.3). Filled once at launch by `AppShell`
/// calling each available feature's `register(in:env:)`; read by the shell and by `MapFeature`
/// and `FeedFeature` for their plug-in slots.
@MainActor
public final class FeatureRegistry {
    public private(set) var tabs: [AppTab: TabRegistration] = [:]
    public private(set) var routes: [Route.Kind: RouteRegistration] = [:]
    public private(set) var mapLayers: [any MapLayerProvider] = []
    public private(set) var mapSheetSections: [any MapSheetSection] = []
    public private(set) var mapActions: [any MapAction] = []
    public private(set) var feedModes: [any FeedMode] = []
    /// The signed-out and first-run flow (O1–O4), supplied by `OnboardingFeature`.
    public private(set) var onboarding: (@MainActor () -> AnyView)?
    /// Debug builds: screens and states reachable as `waypoints://debug/<name>` (PRD 7.1), for
    /// screens no `Route` reaches (search, route preview, an empty or offline state). Names are
    /// lowercase paths such as `feed/empty`. Registered screens win over the shell's built-in
    /// mapping; registering in a release build does nothing harmful but is never opened.
    public private(set) var debugScreens: [String: @MainActor () -> AnyView] = [:]

    public init() {}

    // MARK: Registration

    public func registerTab(_ tab: AppTab, onReselect: (@MainActor () -> Void)? = nil,
                            badge: (@MainActor () -> Int)? = nil,
                            root: @escaping @MainActor () -> AnyView) {
        precondition(tabs[tab] == nil, "Tab \(tab) registered twice")
        tabs[tab] = TabRegistration(tab: tab, root: root, onReselect: onReselect, badge: badge)
    }

    public func registerRoute(_ kind: Route.Kind, presentation: RoutePresentation = .push(tab: nil),
                              view: @escaping @MainActor (Route) -> AnyView?) {
        precondition(routes[kind] == nil, "Route \(kind) registered twice")
        routes[kind] = RouteRegistration(kind: kind, presentation: presentation, view: view)
    }

    public func registerMapLayer(_ provider: any MapLayerProvider) { mapLayers.append(provider) }
    public func registerMapSheetSection(_ section: any MapSheetSection) {
        mapSheetSections.append(section)
        mapSheetSections.sort { $0.order < $1.order }
    }
    public func registerMapAction(_ action: any MapAction) {
        mapActions.append(action)
        mapActions.sort { $0.order < $1.order }
    }
    public func registerFeedMode(_ mode: any FeedMode) {
        feedModes.append(mode)
        feedModes.sort { $0.order < $1.order }
    }
    public func registerOnboarding(_ root: @escaping @MainActor () -> AnyView) {
        precondition(onboarding == nil, "Onboarding registered twice")
        onboarding = root
    }

    public func registerDebugScreen(_ name: String, view: @escaping @MainActor () -> AnyView) {
        debugScreens[name.lowercased()] = view
    }

    // MARK: Lookup

    public var availableTabs: [AppTab] { tabs.keys.sorted() }
    public func canOpen(_ route: Route) -> Bool { routes[route.kind] != nil }
    public func presentation(for route: Route) -> RoutePresentation? { routes[route.kind]?.presentation }
    public func view(for route: Route) -> AnyView? { routes[route.kind]?.view(route) }
}
