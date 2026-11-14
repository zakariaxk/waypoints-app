import Core
import Observation
import UIKit
import DesignSystem
import SwiftUI

/// Owns the router, the registry, and the environment for the app's lifetime, and tracks
/// whether to show onboarding or the tabs.
@MainActor
@Observable
public final class ShellModel {
    public enum Phase: Equatable { case launching, signedOut, onboarding, signedIn }

    public private(set) var phase: Phase = .launching
    public let router: AppRouter
    @ObservationIgnored public let registry: FeatureRegistry
    @ObservationIgnored public let environment: AppEnvironment

    /// `makeEnvironment` receives the shell's router so features can navigate.
    public init(makeEnvironment: @MainActor (any Router) -> AppEnvironment) {
        let router = AppRouter()
        let environment = makeEnvironment(router)
        let registry = FeatureRegistry()
        AppShell.registerFeatures(in: registry, env: environment)
        router.attach(registry)
        self.router = router
        self.registry = registry
        self.environment = environment
        TabBarStyle.apply()
    }

    /// Opens a link: `waypoints://debug/<screen>` in debug builds (PRD 7.1), otherwise a deep
    /// link through `DeepLink`.
    public func open(url: URL) {
        #if DEBUG
        if DebugLinks.handles(url) {
            Task { await DebugLinks.open(url, shell: self) }
            return
        }
        #endif
        router.open(url: url)
    }

    /// Waits until the tabs are showing, up to `timeout`. Used by launch arguments that act
    /// after sign-in (`-wp-open`, `-wp-smoke`).
    public func waitUntilSignedIn(timeout: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while phase != .signedIn {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    /// SAFE-7: when the gateway closes the connection because the account is suspended, sign
    /// out; the sign-in screen then shows `AccountSuspension.message`.
    func observeSuspension() async {
        for await _ in await environment.realtime.suspensions() {
            UserDefaults.standard.set(true, forKey: AccountSuspension.defaultsKey)
            try? await environment.auth.signOut()
        }
    }

    /// Runs for the life of the root view.
    func observeAuth() async {
        for await session in await environment.auth.sessions() {
            let next: Phase = switch session {
            case nil: .signedOut
            case let session? where session.needsOnboarding: .onboarding
            default: .signedIn
            }
            phase = next
            router.setSignedIn(next == .signedIn)
        }
    }
}

/// Section 10.1: opaque `tarmac` bar, `seam` top hairline, selected `sodium`, others `dust`.
@MainActor
enum TabBarStyle {
    static func apply() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.tarmac)
        appearance.shadowColor = UIColor(Color.seam)
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance,
                       appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = UIColor(Color.dust)
            layout.normal.titleTextAttributes = [.foregroundColor: UIColor(Color.dust)]
            layout.selected.iconColor = UIColor(Color.sodium)
            layout.selected.titleTextAttributes = [.foregroundColor: UIColor(Color.sodium)]
            layout.normal.badgeBackgroundColor = UIColor(Color.brake)
        }
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

