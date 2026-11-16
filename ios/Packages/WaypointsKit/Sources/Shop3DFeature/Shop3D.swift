// Shop3DFeature — see docs/PRD.md section 4.27 (GME-1, GME-2, GME-5, GME-6).
import Core
import DesignSystem
import SwiftUI

/// The 3D shop. Entry points: `ShopView(car:)` from the car page (GME-5, wired on the
/// integration pass), and `waypoints://debug/shop` for the first car in the garage.
public enum Shop3DFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.shop, presentation: .fullScreen) { route in
            guard case let .shop(id) = route else { return nil }
            return AnyView(ShopRoute(env: env, carID: id))
        }
        #if DEBUG
        registry.registerDebugScreen("shop") { AnyView(DebugShop(env: env)) }
        #endif
    }
}

/// `Route.shop(carID)`: loads the car, then the shop. Body class from the owner's glyph.
private struct ShopRoute: View {
    let env: AppEnvironment
    let carID: CarID
    @State private var car: Car?
    @State private var shapeClass = "coupe"

    var body: some View {
        NavigationStack {
            if let car {
                ShopView(car: car, shapeClass: shapeClass)
            } else {
                Color.asphalt.ignoresSafeArea()
            }
        }
        .task {
            guard let c = try? await env.garage.car(carID) else { return }
            car = c
            shapeClass = (try? await env.profiles.profile(c.ownerID).markerIcon) ?? "coupe"
        }
    }
}

#if DEBUG
/// `waypoints://debug/shop`: the shop on my first car, in its own body class if the
/// seed profile names one.
private struct DebugShop: View {
    let env: AppEnvironment
    @State private var car: Car?
    @State private var shapeClass = "coupe"

    var body: some View {
        NavigationStack {
            if let car {
                ShopView(car: car, shapeClass: shapeClass)
            } else {
                Color.asphalt.ignoresSafeArea()
            }
        }
        .task {
            guard let me = await env.auth.currentSession()?.userID else { return }
            guard let first = (try? await env.garage.cars(of: me))?.first else { return }
            car = first
            shapeClass = (try? await env.profiles.profile(me).markerIcon) ?? "coupe"
        }
    }
}
#endif
