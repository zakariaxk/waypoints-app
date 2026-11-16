import Core
import DesignSystem
import EngineAudio
import PerformanceModel
import SceneKit
import SwiftUI
import VehicleCatalog

/// Loads the car, its catalog row, and the mod list, then hands the modded spec to the rig —
/// the same `VehicleSpec.from` → `modified` → `ModCatalog.mod` path the Strip uses (GME-4).
struct DriveScreen: View {
    let env: AppEnvironment
    let carID: CarID
    @State private var model: DriveModel?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.asphalt.ignoresSafeArea()
            if let model {
                DriveView(model: model)
            } else if failed {
                VStack(spacing: Space.s16) {
                    Text("We couldn't put this car on the loop.", bundle: .module)
                        .typeStyle(.body).foregroundStyle(Color.chalk)
                    QuietButton("Close") { dismiss() }
                }
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { model?.stop() }
    }

    private func load() async {
        guard let car = try? await env.garage.car(carID) else { failed = true; return }
        var variant: CatalogVariant?
        if let id = car.catalogVariantID { variant = try? await env.catalog.variant(id) }
        guard let base = VehicleSpec.from(variant: variant, car: car) else { failed = true; return }
        let mods = car.mods.compactMap(ModCatalog.mod)
        model = DriveModel(car: car, spec: modified(base, mods: mods, high: false), mods: mods)
    }
}

// MARK: The screen

private struct DriveView: View {
    @State var model: DriveModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SceneView(scene: model.track.scene, pointOfView: model.track.camera,
                      preferredFramesPerSecond: 60, antialiasingMode: .multisampling2X, delegate: model)
                .ignoresSafeArea()
            hud
        }
        .background(Color.asphalt.ignoresSafeArea())
        .persistentSystemOverlays(.hidden)
        .onAppear { model.start() }
    }

    private var hud: some View {
        VStack {
            HStack {
                QuietButton("Close") { dismiss() }
                Spacer()
                Readout(Format.number(model.speedMph), unit: "mph", token: .readoutL)
                Spacer()
                QuietButton("Reset") { model.reset() }
            }
            .padding(.horizontal, Space.margin)
            .padding(.top, Space.s8)
            Spacer()
            HStack(alignment: .bottom, spacing: Space.s24) {
                Pedal(label: Text("Brake", bundle: .module), tint: .brake, value: $model.brake)
                VStack(spacing: Space.s8) {
                    Text(verbatim: "\(model.gear + 1)").typeStyle(.readoutM).foregroundStyle(Color.chalk)
                    SteerPad(value: $model.steer)
                }
                Pedal(label: Text("Throttle", bundle: .module), tint: .sodium, value: $model.throttle)
            }
            .padding(.horizontal, Space.margin)
            .padding(.bottom, Space.margin)
        }
    }
}

/// A momentary pedal: drag inside the capsule to meter 0–1, release to let off.
private struct Pedal: View {
    let label: Text
    let tint: Color
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.tarmac)
                Capsule().fill(tint).frame(height: proxy.size.height * value)
                label.typeStyle(.label).foregroundStyle(Color.chalk)
                    .rotationEffect(.degrees(-90))
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value = max(0, min(1, Double(1 - $0.location.y / proxy.size.height))) }
                .onEnded { _ in value = 0 })
        }
        .frame(width: Size.row * 1.4, height: Size.row * 3)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            value = direction == .increment ? 1 : 0
        }
    }
}

/// A self-centering steering strip: drag left/right, release to centre.
private struct SteerPad: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Capsule().fill(Color.tarmac)
                Circle().fill(Color.sodium)
                    .frame(width: proxy.size.height * 0.8, height: proxy.size.height * 0.8)
                    .offset(x: value * (proxy.size.width - proxy.size.height) / 2)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value = max(-1, min(1, Double($0.location.x / proxy.size.width) * 2 - 1)) }
                .onEnded { _ in value = 0 })
        }
        .frame(width: Size.row * 3.6, height: Size.row)
        .accessibilityElement()
        .accessibilityLabel(Text("Steering", bundle: .module))
        .accessibilityAdjustableAction { direction in
            value = direction == .increment ? 0.5 : -0.5
        }
    }
}

// MARK: The model

/// Owns the scene, the rig, and the synth. SceneKit calls `renderer(_:didSimulatePhysicsAtTime:)`
/// once a frame from the main run loop — no locks, no allocations inside it.
@MainActor @Observable
final class DriveModel: NSObject, SCNSceneRendererDelegate {
    let track: TrackKit
    let rig: CarRig
    let synth = EngineSynth()
    var throttle = 0.0
    var brake = 0.0
    var steer = 0.0
    private(set) var speedMph = 0.0
    private(set) var gear = 0
    private var lastTime: TimeInterval?

    init(car: Car, spec: VehicleSpec, mods: [Mod]) {
        track = DriveScene.make(paintHex: car.colorHex)
        rig = CarRig(spec: spec, paintHex: car.colorHex,
                     at: track.startPosition, heading: track.startHeading)
        super.init()
        track.scene.rootNode.addChildNode(rig.node)
        // Wheel nodes hang off the chassis: their transform relative to it is the attachment.
        for w in rig.vehicle.wheels { rig.node.addChildNode(w.node) }
        track.scene.physicsWorld.addBehavior(rig.vehicle)
        synth.apply(.drive(spec, mods: mods))
    }

    func start() { synth.start() }
    func stop() { synth.stop() }

    func reset() { rig.reset(to: track.startPosition, heading: track.startHeading) }

    nonisolated func renderer(_ renderer: any SCNSceneRenderer, didSimulatePhysicsAtTime time: TimeInterval) {
        MainActor.assumeIsolated { frame(time) }
    }

    private func frame(_ time: TimeInterval) {
        let dt = min(lastTime.map { time - $0 } ?? 1.0 / 60, 0.05)
        lastTime = time
        rig.drive(throttle: throttle, brake: brake, steer: steer, dt: dt)
        speedMph = rig.speedMps * 2.23694
        gear = rig.gear
        synth.set(rpm: rig.rpm, load: throttle)
        chaseCamera()
    }

    private func chaseCamera() {
        let cam = track.camera
        let pos = rig.node.presentation.simdPosition
        let fwd = rig.node.presentation.simdWorldFront
        let target = pos - fwd * 7.5 + SIMD3<Float>(0, 3.4, 0)
        cam.simdPosition = simd_mix(cam.simdPosition, target, SIMD3(repeating: 0.14))
        cam.simdLook(at: pos + SIMD3<Float>(0, 1.4, 0))
    }
}
