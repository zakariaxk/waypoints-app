import Core
import RealityKit
import SwiftUI
import VehicleCatalog

/// State behind `ShopView` (GME-2). Every edit mutates the scene in place; nothing is
/// rebuilt on the gesture path and allocations only happen on an explicit part swap.
@MainActor
@Observable
public final class ShopModel {
    public let car: Car
    public let shape: CarShape

    /// Paint shown on the body. `family` is a picker's family; `customHex` keeps the
    /// car's own `colorHex` as one more swatch.
    public private(set) var family: PaintFamily?
    public private(set) var customHex: String?
    public private(set) var wheelStyle: WheelStyle
    public private(set) var clearance: Clearance
    public private(set) var splitterOn = false
    public private(set) var wingOn = false

    /// Hex string feeding the paint material right now.
    public var paintHex: String { customHex ?? family?.hex ?? "#5E6266" }

    private var assembly: CarAssembly?
    private var splitter: Entity?
    private var wing: Entity?

    public init(car: Car, shapeClass: String = "sedan") {
        self.car = car
        self.shape = CarShape(className: shapeClass)
        self.customHex = car.colorHex
        self.family = car.colorHex == nil ? car.colorFamily.flatMap(PaintFamily.init(rawValue:)) : nil
        self.clearance = car.clearance
        self.wheelStyle = .spokes
    }

    // MARK: Scene

    /// Installs the car, ground, and lights into a `RealityViewCameraContent` (its `make`
    /// closure). Camera is the virtual camera orbit controls drive.
    func installScene(in content: inout RealityViewCameraContent) {
        let assembly = CarBuilder.car(shape: shape, paintHex: paintHex, wheelStyle: wheelStyle)
        CarBuilder.apply(clearance: clearance, to: assembly)
        self.assembly = assembly
        content.add(assembly.root)
        content.camera = .virtual
        content.cameraTarget = assembly.root

        let ground = ModelEntity(mesh: .generatePlane(width: 30, depth: 30),
                                 materials: [CarBuilder.Materials.ground])
        ground.position = .zero
        content.add(ground)

        // Sodium-shop key from above the nose, dim xenon rim from the tail; a spot overhead
        // pools light on the paint. Ambient stays black — DES-8 dark scene.
        let key = DirectionalLight()
        key.light.intensity = 900
        key.light.color = CarBuilder.ui(0xFFD9A0)
        key.shadow = DirectionalLightComponent.Shadow(shadowProjection: .automatic(maximumDistance: 12),
                                                      depthBias: 2)
        key.look(at: .zero, from: [3, 4, -4], relativeTo: nil)
        content.add(key)

        let rim = DirectionalLight()
        rim.light.intensity = 500
        rim.light.color = CarBuilder.ui(0xBFE2FF)
        rim.look(at: .zero, from: [-3, 2.5, 4], relativeTo: nil)
        content.add(rim)

        let spot = SpotLight()
        spot.light.intensity = 4000
        spot.light.innerAngleInDegrees = 35
        spot.light.outerAngleInDegrees = 80
        spot.light.attenuationRadius = 9
        spot.position = [0, 4.5, 0.5]
        spot.look(at: .zero, from: spot.position, relativeTo: nil)
        content.add(spot)

        if splitterOn { addSplitter() }
        if wingOn { addWing() }
    }

    // MARK: Swaps

    func pickFamily(_ family: PaintFamily) {
        self.family = family
        customHex = nil
        repaint()
    }

    func pickCustom() {
        guard car.colorHex != nil else { return }
        customHex = car.colorHex
        family = nil
        repaint()
    }

    func pickWheels(_ style: WheelStyle) {
        wheelStyle = style
        if let assembly { CarBuilder.setWheels(style, on: assembly.wheelsRoot, shape: shape) }
    }

    func pickClearance(_ clearance: Clearance) {
        self.clearance = clearance
        if let assembly { CarBuilder.apply(clearance: clearance, to: assembly) }
    }

    func toggleSplitter(_ on: Bool) {
        splitterOn = on
        if on { addSplitter() } else { splitter?.removeFromParent(); splitter = nil }
    }

    func toggleWing(_ on: Bool) {
        wingOn = on
        if on { addWing() } else { wing?.removeFromParent(); wing = nil }
    }

    // MARK: Private

    private func repaint() {
        if let assembly { CarBuilder.apply(paintHex: paintHex, to: assembly) }
    }

    private func addSplitter() {
        guard let assembly, splitter == nil else { return }
        let part = CarBuilder.splitter(shape: shape)
        assembly.body.addChild(part)
        splitter = part
    }

    private func addWing() {
        guard let assembly, wing == nil else { return }
        let part = CarBuilder.wing(shape: shape)
        assembly.body.addChild(part)
        wing = part
    }
}
