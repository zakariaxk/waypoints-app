import Core
import Foundation
import Observation
import SwiftUI

/// A route being shown modally.
public struct PresentedRoute: Identifiable, Hashable {
    public let id = UUID()
    public let route: Route
}

/// The app's `Router`: resolves a `Route` through the registry and pushes or presents it.
/// Routes opened while signed out (deep links) wait until sign-in (section 10.10, X3).
@MainActor
@Observable
public final class AppRouter: Router {
    public var selectedTab: AppTab = .map
    public var paths: [AppTab: [Route]] = [:]
    public var sheet: PresentedRoute?
    public var fullScreen: PresentedRoute?

    @ObservationIgnored private var registry: FeatureRegistry?
    @ObservationIgnored private var isSignedIn = false
    @ObservationIgnored private var pending: Route?

    public nonisolated init() {}

    func attach(_ registry: FeatureRegistry) {
        self.registry = registry
        if let first = registry.availableTabs.first { selectedTab = first }
    }

    func setSignedIn(_ signedIn: Bool) {
        isSignedIn = signedIn
        if !signedIn {
            paths = [:]
            sheet = nil
            fullScreen = nil
        } else if let route = pending {
            pending = nil
            open(route)
        }
    }

    public func open(_ route: Route) {
        guard isSignedIn else {
            pending = route
            return
        }
        guard let registry, let presentation = registry.presentation(for: route) else { return }
        switch presentation {
        case .push(let tab):
            let target = tab.flatMap { registry.tabs[$0] == nil ? nil : $0 } ?? selectedTab
            guard registry.tabs[target] != nil else {
                sheet = PresentedRoute(route: route)    // no tab to push onto
                return
            }
            sheet = nil
            fullScreen = nil
            selectedTab = target
            paths[target, default: []].append(route)
        case .sheet:
            sheet = PresentedRoute(route: route)
        case .fullScreen:
            fullScreen = PresentedRoute(route: route)
        }
    }

    public func open(url: URL) {
        if let route = DeepLink.route(from: url) { open(route) }
    }

    /// Tapping the current tab pops to its root; tapping it at the root calls the feature's
    /// reselect hook (Map recenters). Section 10.1.
    func select(_ tab: AppTab) {
        guard tab == selectedTab else {
            selectedTab = tab
            return
        }
        if paths[tab]?.isEmpty == false {
            paths[tab] = []
        } else {
            registry?.tabs[tab]?.onReselect?()
        }
    }

    var tabSelection: Binding<AppTab> {
        Binding(get: { self.selectedTab }, set: { self.select($0) })
    }

    func path(for tab: AppTab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }
}
