import Core
import RealityKit
import simd
import UIKit

/// The wheel faces the shop can generate (GME-2). All procedural.
public enum WheelStyle: String, Sendable, Hashable, CaseIterable {
    case steelie, spokes, mesh
}

/// The generated car plus the pieces swaps mutate, all on the main actor (RealityKit
/// entities are not `Sendable`).
@MainActor
public final class CarAssembly {
    /// Everything, centered at the origin, tires on y = 0. Front is -Z.
    public let root: Entity
    /// Hull, cabin, lights, and aero; `position.y` drops with clearance (GAR-12).
    public let body: Entity
    /// Wheels live here so a style swap replaces the children wholesale.
    public let wheelsRoot: Entity
    /// The painted mesh; a colour change rewrites its material in place.
    let hull: ModelEntity
    var paint: PhysicallyBasedMaterial
    public let shape: CarShape

    init(root: Entity, body: Entity, wheelsRoot: Entity, hull: ModelEntity,
         paint: PhysicallyBasedMaterial, shape: CarShape) {
        self.root = root; self.body = body; self.wheelsRoot = wheelsRoot
        self.hull = hull; self.paint = paint; self.shape = shape
    }

    /// Repaint in place; nothing is rebuilt.
    func setPaint(hex: String) {
        guard let rgb = CarBuilder.rgb(hex) else { return }
        paint.baseColor = .init(tint: CarBuilder.ui(rgb))
        hull.model?.materials = [paint]
    }
}

/// Procedural stylized bodies (GME-1). No real manufacturer's design: one tapered hull,
/// a glass greenhouse, and primitive wheels. Whole car is ~2k triangles.
@MainActor
public enum CarBuilder {

    // MARK: Public

    public static func car(shape: CarShape, paintHex: String, wheelStyle: WheelStyle) -> CarAssembly {
        var paint = PhysicallyBasedMaterial()
        paint.baseColor = .init(tint: ui(Self.rgb(paintHex) ?? 0x5E6266))
        paint.roughness = 0.35
        paint.metallic = 0.65
        paint.clearcoat = 1.0
        paint.clearcoatRoughness = 0.15

        let body = Entity()

        // Lower hull: a wedge, nose tapers in more than the tail.
        let hull = ModelEntity()
        if let hullMesh = wedge(length: shape.length, width: shape.width,
                                y0: sill(of: shape), y1: sill(of: shape) + shape.hullHeight,
                                frontInset: shape.length * 0.14, rearInset: shape.length * 0.06,
                                topScale: 0.97) {
            hull.model = ModelComponent(mesh: hullMesh, materials: [paint])
        }
        body.addChild(hull)

        // Greenhouse: dark glass canopy set into the hull top.
        let cabin = Entity()
        let zNose = -shape.length / 2
        let cabinFront = zNose + shape.length * shape.cabinFront
        let cabinRear = zNose + shape.length * shape.cabinRear
        let yTop = sill(of: shape) + shape.hullHeight
        if let cabinMesh = wedge(length: cabinRear - cabinFront, width: shape.width * 0.9,
                                 y0: 0, y1: shape.cabinHeight,
                                 frontInset: (cabinRear - cabinFront) * 0.28,
                                 rearInset: (cabinRear - cabinFront) * 0.18,
                                 topScale: 0.82) {
            let glass = ModelEntity(mesh: cabinMesh, materials: [Materials.glass])
            glass.position = [0, yTop - 0.01, (cabinFront + cabinRear) / 2]
            cabin.addChild(glass)
        }
        body.addChild(cabin)

        // Lamps: thin emissive boxes at the wedges' noses.
        let lampY = sill(of: shape) + shape.hullHeight * 0.62
        let front = ModelEntity(mesh: .generateBox(size: [shape.width * 0.7, 0.07, 0.02]),
                                materials: [Materials.lampFront])
        front.position = [0, lampY, -shape.length / 2 + 0.02]
        body.addChild(front)
        let rear = ModelEntity(mesh: .generateBox(size: [shape.width * 0.7, 0.06, 0.02]),
                               materials: [Materials.lampRear])
        rear.position = [0, lampY, shape.length / 2 - 0.02]
        body.addChild(rear)

        let wheelsRoot = Entity()
        setWheels(wheelStyle, on: wheelsRoot, shape: shape)

        let root = Entity()
        root.addChild(body)
        root.addChild(wheelsRoot)
        return CarAssembly(root: root, body: body, wheelsRoot: wheelsRoot,
                           hull: hull, paint: paint, shape: shape)
    }

    /// Repaint in place; nothing is rebuilt.
    public static func apply(paintHex: String, to assembly: CarAssembly) {
        assembly.setPaint(hex: paintHex)
    }

    /// Stock, lowered, slammed (GAR-12): the body drops, the tires stay on the floor.
    public static func apply(clearance: Clearance, to assembly: CarAssembly) {
        let drop: Float = switch clearance {
        case .stock: 0
        case .lowered: 0.05
        case .slammed: 0.10
        }
        assembly.body.position.y = -drop
    }

    public static func setWheels(_ style: WheelStyle, on wheelsRoot: Entity, shape: CarShape) {
        wheelsRoot.children.removeAll()
        for x in [-shape.track / 2, shape.track / 2] as [Float] {
            for z in [-shape.wheelbase / 2, shape.wheelbase / 2] as [Float] {
                let w = wheel(style: style, radius: shape.wheelRadius, width: shape.wheelWidth)
                w.position = [x, shape.wheelRadius, z]
                wheelsRoot.addChild(w)
            }
        }
    }

    // MARK: Aero

    /// Front splitter: a flat blade under the nose.
    public static func splitter(shape: CarShape) -> Entity {
        let blade = ModelEntity(
            mesh: .generateBox(size: [shape.width * 0.96, 0.025, 0.28]),
            materials: [Materials.darkMetal])
        blade.position = [0, sill(of: shape) * 0.55 + 0.02, -shape.length / 2 - 0.10]
        return blade
    }

    /// Rear wing: a blade on two struts.
    public static func wing(shape: CarShape) -> Entity {
        let wing = Entity()
        let y = sill(of: shape) + shape.hullHeight + (shape.cabinHeight * 0.55)
        let z = shape.length / 2 - shape.length * 0.06
        let blade = ModelEntity(
            mesh: .generateBox(size: [shape.width * 0.92, 0.022, 0.20]),
            materials: [Materials.darkMetal])
        blade.position = [0, y, z]
        blade.transform.rotation = simd_quatf(angle: -0.12, axis: [1, 0, 0])
        wing.addChild(blade)
        for x in [-shape.width * 0.3, shape.width * 0.3] as [Float] {
            let strut = ModelEntity(mesh: .generateBox(size: [0.03, 0.16, 0.06]),
                                    materials: [Materials.darkMetal])
            strut.position = [x, y - 0.09, z]
            wing.addChild(strut)
        }
        return wing
    }

    // MARK: Wheels

    static func wheel(style: WheelStyle, radius r: Float, width w: Float) -> Entity {
        let wheel = Entity()
        let tire = ModelEntity(mesh: .generateCylinder(height: w, radius: r),
                               materials: [Materials.rubber])
        tire.transform.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        wheel.addChild(tire)

        let faceR = r * 0.62
        switch style {
        case .steelie:
            let hub = ModelEntity(mesh: .generateCylinder(height: w + 0.01, radius: faceR),
                                  materials: [Materials.rim])
            hub.transform.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            wheel.addChild(hub)
        case .spokes, .mesh:
            let barrel = ModelEntity(mesh: .generateCylinder(height: w * 0.9, radius: faceR),
                                     materials: [Materials.darkMetal])
            barrel.transform.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            wheel.addChild(barrel)
            let count = style == .spokes ? 5 : 12
            let spokeLen = faceR
            for i in 0..<count {
                let spoke = ModelEntity(
                    mesh: .generateBox(size: [w + 0.005, spokeLen, 0.035]),
                    materials: [Materials.rim])
                spoke.transform.rotation = simd_quatf(angle: Float(i) * .pi / Float(count),
                                                      axis: [1, 0, 0])
                wheel.addChild(spoke)
            }
        }
        return wheel
    }

    // MARK: Mesh

    /// A box whose top face is inset on all sides — the tapered volumes a stylized body
    /// needs (hood slopes down at the nose, the greenhouse pinches in). Front is -Z.
    static func wedge(length: Float, width: Float, y0: Float, y1: Float,
                      frontInset: Float, rearInset: Float, topScale: Float) -> MeshResource? {
        let zF = -length / 2, zR = length / 2
        let hw = width / 2, thw = hw * topScale
        let zTF = zF + frontInset, zTR = zR - rearInset
        let b: [SIMD3<Float>] = [
            [-hw, y0, zF], [hw, y0, zF], [hw, y0, zR], [-hw, y0, zR],
        ]
        let t: [SIMD3<Float>] = [
            [-thw, y1, zTF], [thw, y1, zTF], [thw, y1, zTR], [-thw, y1, zTR],
        ]
        // Quads as corners of b/t; winding is fixed per face by `quad`.
        let faces: [[SIMD3<Float>]] = [
            [t[0], t[1], b[1], b[0]],   // front
            [t[2], t[3], b[3], b[2]],   // rear
            [t[3], t[0], b[0], b[3]],   // left
            [t[1], t[2], b[2], b[1]],   // right
            [t[0], t[3], t[2], t[1]],   // top
            [b[0], b[1], b[2], b[3]],   // bottom
        ]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        let center = SIMD3<Float>(0, (y0 + y1) / 2, 0)
        for face in faces {
            quad(face, around: center, positions: &positions, normals: &normals, indices: &indices)
        }
        var descriptor = MeshDescriptor(name: "wedge")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Two flat-shaded triangles per quad, wound so the normal points away from `center`.
    private static func quad(_ c: [SIMD3<Float>], around center: SIMD3<Float>,
                             positions: inout [SIMD3<Float>], normals: inout [SIMD3<Float>],
                             indices: inout [UInt32]) {
        var corners = c
        let mid = (c[0] + c[1] + c[2] + c[3]) / 4
        var n = simd_normalize(simd_cross(c[1] - c[0], c[2] - c[0]))
        if simd_dot(n, mid - center) < 0 {
            n = -n
            corners = [c[0], c[3], c[2], c[1]]
        }
        let base = UInt32(positions.count)
        positions += [corners[0], corners[1], corners[2], corners[0], corners[2], corners[3]]
        normals += [n, n, n, n, n, n]
        indices += [base, base + 1, base + 2, base + 3, base + 4, base + 5]
    }

    // MARK: Shared scene materials

    enum Materials {
        @MainActor static let glass: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0x0B0C0E))
            m.roughness = 0.08
            m.metallic = 0.9
            return m
        }()
        @MainActor static let rubber: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0x121212))
            m.roughness = 0.92
            return m
        }()
        @MainActor static let rim: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0xC9CBD0))
            m.roughness = 0.32
            m.metallic = 0.9
            return m
        }()
        @MainActor static let darkMetal: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0x26272A))
            m.roughness = 0.5
            m.metallic = 0.8
            return m
        }()
        @MainActor static let lampFront: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0xBFD9E8))
            m.emissiveColor = .init(color: ui(0xBFD9E8))
            m.emissiveIntensity = 0.8
            return m
        }()
        @MainActor static let lampRear: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0x8A1620))
            m.emissiveColor = .init(color: ui(0x8A1620))
            m.emissiveIntensity = 0.6
            return m
        }()
        @MainActor static let ground: PhysicallyBasedMaterial = {
            var m = PhysicallyBasedMaterial()
            m.baseColor = .init(tint: ui(0x131314))
            m.roughness = 0.85
            return m
        }()
    }

    // MARK: Helpers

    static func sill(of shape: CarShape) -> Float { shape.wheelRadius * 0.42 }

    /// Scene materials only; the token layer does not reach RealityKit.
    static func ui(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func rgb(_ hex: String) -> UInt32? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }
}
