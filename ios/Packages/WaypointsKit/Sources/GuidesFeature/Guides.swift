// GuidesFeature — see docs/PRD.md section 4.26/4.27.
// KNW-2/3/4: a repair-guide browser reached from the Garage tab (route `guides`).
import Core
import DesignSystem
import SwiftUI

public enum GuidesFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let ctx = GuidesContext(env: env, registry: registry)
        registry.registerRoute(.guides, presentation: .push(tab: .garage)) { route in
            guard case .guides = route else { return nil }
            return AnyView(GuidesScreen(ctx: ctx))
        }
        registry.registerRoute(.guide, presentation: .push(tab: .garage)) { route in
            guard case let .guide(id) = route else { return nil }
            return AnyView(GuideDetailScreen(ctx: ctx, guideID: id))
        }
        #if DEBUG
        registry.registerDebugScreen("guides") { AnyView(NavigationStack { GuidesScreen(ctx: ctx) }) }
        #if DEBUG
        registry.registerDebugScreen("guide") { AnyView(DebugGuide(ctx: ctx)) }
        #endif
    }
}

@MainActor
final class GuidesContext {
    let env: AppEnvironment
    let registry: FeatureRegistry
    init(env: AppEnvironment, registry: FeatureRegistry) { self.env = env; self.registry = registry }
}

#if DEBUG
/// `waypoints://debug/guide`: the first guide the seed offers.
private struct DebugGuide: View {
    let ctx: GuidesContext
    @State private var guide: Guide?

    var body: some View {
        NavigationStack {
            if let guide { GuideDetailScreen(ctx: ctx, guide: guide) } else { Color.asphalt.ignoresSafeArea() }
        }
        .task {
            if guide == nil { guide = try? await ctx.env.guides.search("").first }
        }
    }
}
#endif
