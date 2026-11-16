import SceneKit

// The loop (GME-3): a closed Catmull-Rom spline through authored control points, drawn as a
// flat ribbon with shoulders, kerb edges, a start/finish gantry, and scattered procedural
// trees. All geometry is generated; there are no bundled assets.

struct TrackKit {
    let scene: SCNScene
    /// Closed centerline samples, y = 0.
    let line: [SIMD3<Float>]
    /// Grid slot and heading the car starts at.
    let startPosition: SCNVector3
    let startHeading: Float
    let camera: SCNNode
}

enum DriveScene {
    /// Road half-width in metres.
    static let halfW: Float = 4.5

    /// Authored control polygon (~1.4 km lap).
    private static let control: [SIMD2<Float>] = [
        [0, 0], [70, -8], [130, -30], [165, -80], [160, -140], [120, -175],
        [55, -180], [10, -150], [-40, -160], [-95, -185], [-155, -170],
        [-195, -120], [-185, -55], [-140, -15], [-80, 8],
    ]

    /// Catmull-Rom sample of the closed control polygon, `n` points per span.
    static func sampleLine(spans n: Int = 14) -> [SIMD3<Float>] {
        let c = control, m = c.count
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(m * n)
        for i in 0..<m {
            let p0 = c[(i - 1 + m) % m], p1 = c[i], p2 = c[(i + 1) % m], p3 = c[(i + 2) % m]
            for j in 0..<n {
                let t = Float(j) / Float(n), t2 = t * t, t3 = t2 * t
                func s(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(SIMD3(s(p0.x, p1.x, p2.x, p3.x), 0, s(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }

    static func make(paintHex: String?) -> TrackKit {
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1)
        scene.fogStartDistance = 120
        scene.fogEndDistance = 320
        scene.fogColor = UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 1)

        // Ground: a large static slab; the flat road needs no surface of its own.
        let ground = SCNNode(geometry: SCNBox(width: 900, height: 1, length: 900, chamferRadius: 0))
        ground.geometry?.firstMaterial?.diffuse.contents = UIColor(red: 0.05, green: 0.07, blue: 0.06, alpha: 1)
        ground.position = SCNVector3(0, -0.5, -90)
        ground.physicsBody = .static()
        scene.rootNode.addChildNode(ground)

        let line = sampleLine()
        let shoulder = ribbon(line, halfWidth: halfW + 1.6, y: 0.02,
                              color: UIColor(white: 0.10, alpha: 1))
        let road = ribbon(line, halfWidth: halfW, y: 0.05, color: UIColor(white: 0.16, alpha: 1))
        let kerbL = ribbon(line, halfWidth: 0.4, offset: halfW - 0.2, y: 0.07, color: .white)
        let kerbR = ribbon(line, halfWidth: 0.4, offset: -(halfW - 0.2), y: 0.07, color: .white)
        scene.rootNode.addChildNode(shoulder)
        scene.rootNode.addChildNode(road)
        scene.rootNode.addChildNode(kerbL)
        scene.rootNode.addChildNode(kerbR)
        gantry(at: line[0], heading: heading(line, 0), into: scene)
        trees(around: line, into: scene)
        markers(around: line, into: scene)

        // A low ambient and one directional "floodlight" — dark, one accent (DES-8).
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.35, alpha: 1)
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 700
        sun.eulerAngles = SCNVector3(-Float.pi / 3, 0.4, 0)
        scene.rootNode.addChildNode(sun)

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zFar = 500
        cam.camera?.wantsHDR = true
        scene.rootNode.addChildNode(cam)

        let heading0 = heading(line, 0)
        return TrackKit(scene: scene, line: line,
                        startPosition: SCNVector3(line[0].x, 0.9, line[0].z),
                        startHeading: heading0, camera: cam)
    }

    /// Tangent angle (yaw) of the closed line at index i. Vehicle forward is -Z, so yaw 0
    /// faces -Z; atan2 is arranged to match `SCNVector4(0,1,0,yaw)`.
    static func heading(_ line: [SIMD3<Float>], _ i: Int) -> Float {
        let a = line[i], b = line[(i + 1) % line.count]
        let d = b - a
        return atan2(-d.x, -d.z)
    }

    /// A flat closed ribbon: two verts per sample at `offset ± width/…`, wrapped.
    private static func ribbon(_ line: [SIMD3<Float>], halfWidth: Float, offset: Float = 0,
                               y: Float, color: UIColor) -> SCNNode {
        let n = line.count
        var verts: [SCNVector3] = []
        verts.reserveCapacity(n * 2)
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []
        for i in 0..<n {
            let t = heading(line, i)
            let nx = cos(t), nz = -sin(t)        // left of travel
            let c = line[i]
            verts.append(SCNVector3(c.x + nx * (offset + halfWidth), y, c.z + nz * (offset + halfWidth)))
            verts.append(SCNVector3(c.x + nx * (offset - halfWidth), y, c.z + nz * (offset - halfWidth)))
            normals.append(SCNVector3(0, 1, 0)); normals.append(SCNVector3(0, 1, 0))
            let a = UInt32(i * 2), b = UInt32((i * 2 + 2) % (n * 2))
            indices += [a, b, a + 1, b, b + 1, a + 1]
        }
        let src = SCNGeometrySource(vertices: verts)
        let nrm = SCNGeometrySource(normals: normals)
        let el = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let g = SCNGeometry(sources: [src, nrm], elements: [el])
        g.firstMaterial = SCNMaterial()
        g.firstMaterial?.diffuse.contents = color
        g.firstMaterial?.isDoubleSided = true
        g.firstMaterial?.lightingModel = .lambert
        return SCNNode(geometry: g)
    }

    /// Two posts and a beam across the road at the start line, with the accent stripe.
    private static func gantry(at p: SIMD3<Float>, heading: Float, into scene: SCNScene) {
        let root = SCNNode()
        root.position = SCNVector3(p.x, 0, p.z)
        root.rotation = SCNVector4(0, 1, 0, heading)
        let accent = UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)   // sodium
        for side: Float in [-1, 1] {
            let post = SCNNode(geometry: SCNBox(width: 0.35, height: 5.4, length: 0.35, chamferRadius: 0.05))
            post.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.2, alpha: 1)
            post.position = SCNVector3(side * (halfW + 0.9), 2.7, 0)
            root.addChildNode(post)
        }
        let beam = SCNNode(geometry: SCNBox(width: CGFloat(halfW + 0.9) * 2 + 0.35, height: 0.8, length: 0.6, chamferRadius: 0.05))
        beam.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.16, alpha: 1)
        beam.position = SCNVector3(0, 5.4, 0)
        root.addChildNode(beam)
        let stripe = SCNNode(geometry: SCNBox(width: CGFloat(halfW + 0.9) * 2, height: 0.18, length: 0.66, chamferRadius: 0))
        stripe.geometry?.firstMaterial?.diffuse.contents = accent
        stripe.geometry?.firstMaterial?.emission.contents = accent
        stripe.position = SCNVector3(0, 5.4, 0)
        root.addChildNode(stripe)
        scene.rootNode.addChildNode(root)
    }

    /// Deterministic (seeded LCG) trees outside the ribbon — cone on a trunk, no physics.
    private static func trees(around line: [SIMD3<Float>], into scene: SCNScene) {
        var seed: UInt64 = 0x2F6E2B1A
        func rand() -> Float {
            seed &*= 6364136223846793005; seed &+= 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        let leaf = UIColor(red: 0.09, green: 0.16, blue: 0.11, alpha: 1)
        let bark = UIColor(white: 0.12, alpha: 1)
        var placed = 0
        while placed < 60 {
            let i = Int(rand() * Float(line.count))
            let angle = rand() * .pi * 2
            let d = halfW + 8 + rand() * 55
            let p = line[i] + SIMD3(cos(angle) * d, 0, sin(angle) * d)
            var clear = true
            for q in line where distance_squared(q, p) < 15 * 15 { clear = false; break }
            guard clear else { continue }
            let h = 3 + rand() * 5
            let tree = SCNNode()
            let trunk = SCNNode(geometry: SCNCylinder(radius: 0.14, height: CGFloat(h) * 0.4))
            trunk.geometry?.firstMaterial?.diffuse.contents = bark
            trunk.position = SCNVector3(0, h * 0.2, 0)
            let crown = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: CGFloat(h) * 0.32, height: CGFloat(h)))
            crown.geometry?.firstMaterial?.diffuse.contents = leaf
            crown.position = SCNVector3(0, h * 0.4 + h * 0.5, 0)
            tree.addChildNode(trunk); tree.addChildNode(crown)
            tree.position = SCNVector3(p.x, 0, p.z)
            scene.rootNode.addChildNode(tree)
            placed += 1
        }
    }

    /// Low marker blocks on the outside of every third span — braking references, and a
    /// static body so an off keeps the car near the loop.
    private static func markers(around line: [SIMD3<Float>], into scene: SCNScene) {
        let accent = UIColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        for i in stride(from: 0, to: line.count, by: 8) {
            let t = heading(line, i)
            let side: Float = (i / 8) % 2 == 0 ? 1 : -1
            let nx = cos(t) * side * (halfW + 2.2), nz = -sin(t) * side * (halfW + 2.2)
            let block = SCNNode(geometry: SCNBox(width: 0.5, height: 1.0, length: 2.4, chamferRadius: 0.08))
            block.geometry?.firstMaterial?.diffuse.contents = (i / 8) % 3 == 0 ? accent : UIColor(white: 0.3, alpha: 1)
            block.position = SCNVector3(line[i].x + nx, 0.5, line[i].z + nz)
            block.rotation = SCNVector4(0, 1, 0, t)
            block.physicsBody = .static()
            scene.rootNode.addChildNode(block)
        }
    }
}
