import Core
import DesignSystem
import SwiftUI

/// Root view of the app.
public struct AppShellView: View {
    let shell: ShellModel

    public init(shell: ShellModel) { self.shell = shell }

    public var body: some View {
        content
            .preferredColorScheme(.dark)
            .task { await shell.observeAuth() }
            .onOpenURL { shell.router.open(url: $0) }
            // Universal links usually arrive through onOpenURL; some launch paths deliver
            // them only as a browsing-web user activity, so handle both (LINK-2).
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { shell.router.open(url: url) }
            }
    }

    @ViewBuilder private var content: some View {
        switch shell.phase {
        case .launching:
            Color.asphalt.ignoresSafeArea()
        case .signedOut, .onboarding:
            if let onboarding = shell.registry.onboarding { onboarding() } else { SignedOutPlaceholder() }
        case .signedIn:
            if shell.registry.availableTabs.isEmpty {
                SignedOutPlaceholder()
            } else {
                TabShell(router: shell.router, registry: shell.registry)
            }
        }
    }
}

/// Five tabs at most, shown only when a feature registered them (section 10.1).
struct TabShell: View {
    @Bindable var router: AppRouter
    let registry: FeatureRegistry

    var body: some View {
        TabView(selection: router.tabSelection) {
            ForEach(registry.availableTabs, id: \.self) { tab in
                let registration = registry.tabs[tab]
                Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    NavigationStack(path: router.path(for: tab)) {
                        (registration?.root() ?? AnyView(EmptyView()))
                            .navigationDestination(for: Route.self) { route in
                                registry.view(for: route) ?? AnyView(EmptyView())
                            }
                    }
                }
                .badge(registration?.badge?() ?? 0)
            }
        }
        .tint(Color.sodium)
        .sheet(item: $router.sheet) { presented in
            registry.view(for: presented.route)
        }
        .fullScreenCover(item: $router.fullScreen) { presented in
            registry.view(for: presented.route)
        }
    }
}

/// Shown while no onboarding feature is registered, and while signed in with no tabs
/// available. The O1 layout (section 10.2) without its controls, since a control that does
/// nothing yet is not allowed on screen (section 9.11).
struct SignedOutPlaceholder: View {
    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: Space.s8) {
                Spacer().frame(height: proxy.size.height / 3 - Space.s48)
                Text("Waypoints")
                    .typeStyle(.display)
                    .foregroundStyle(Color.chalk)
                    .accessibilityAddTraits(.isHeader)
                Text("See who's out. Find the meet. Show the build.")
                    .typeStyle(.body)
                    .foregroundStyle(Color.dust)
                Spacer()
            }
            .padding(.horizontal, Space.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.asphalt.ignoresSafeArea())
    }
}

#Preview("Signed out") {
    SignedOutPlaceholder()
        .preferredColorScheme(.dark)
}
