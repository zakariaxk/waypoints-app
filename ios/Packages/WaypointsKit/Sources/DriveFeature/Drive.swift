// DriveFeature — the closed-loop test drive (docs/PRD.md section 4.27, GME-3/4/5/6).
// SceneKit's raycast vehicle (SCNPhysicsVehicle) fed by PerformanceModel's torque curve and
// gearing; the exhaust is EngineAudio's synth under the car's mod SoundDelta.
import Core
import DesignSystem
import EngineAudio
import PerformanceModel
import SwiftUI
import VehicleCatalog

public enum DriveFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerRoute(.drive, presentation: .fullScreen) { route in
            guard case let .drive(id) = route else { return nil }
            return AnyView(DriveScreen(env: env, carID: id))
        }
        #if DEBUG
        registry.registerDebugScreen("drive") { AnyView(DebugDrive(env: env)) }
        #endif
    }
}

#if DEBUG
/// `waypoints://debug/drive`: the loop with the signed-in driver's first specced car.
private struct DebugDrive: View {
    let env: AppEnvironment
    @State private var carID: CarID?

    var body: some View {
        ZStack {
            Color.asphalt.ignoresSafeArea()
            if let carID { DriveScreen(env: env, carID: carID) } else { ProgressView() }
        }
        .preferredColorScheme(.dark)
        .task {
            guard let me = await env.auth.currentSession()?.userID else { return }
            carID = try? await env.garage.cars(of: me).first?.id
        }
    }
}
#endif

extension SoundProfile {
    /// The synthesizer profile for a spec with mods — same recipe as ModSim's (features cannot
    /// share code; keep the two copies in step).
    static func drive(_ spec: VehicleSpec, mods: [Mod]) -> SoundProfile {
        var p = SoundProfile(layout: .from(cylinders: spec.cylinders, flat: spec.layout == .flat,
                                           crossPlane: spec.crankPlane == .cross, rotary: spec.layout == .rotary),
                             redline: spec.redline, whistle: spec.aspiration == .turbo || spec.aspiration == .twinCharged)
        if spec.aspiration == .supercharged { p.whine = true }
        for m in mods {
            let s = m.sound
            p.gainDb += s.gainDb
            p.cutoffScale *= s.cutoffScale
            p.brightness += s.brightness
            p.reflection += s.reflection
            if s.removesResonator { p.resonator = false }
            p.crackle = p.crackle || s.crackle
            p.whine = p.whine || s.whine
            p.whistle = (p.whistle || s.whistle) && !s.whine
        }
        p.gainDb = min(p.gainDb, 14)
        return p
    }
}
