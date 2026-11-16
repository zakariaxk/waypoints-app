import Core
import PerformanceModel
import SceneKit

// The SCNPhysicsVehicle built from a (modded) VehicleSpec (GME-4): mass is the curb weight,
// engine force follows PerformanceModel.torque(at:spec:) through the real gear ratios, and
// the driven wheels follow `drivetrain`. Gears shift themselves inside the redline band.
//
// All SCN objects live on the main actor: SceneKit drives an SCNView's render loop — and so
// this delegate path — from the main run loop, and the HUD reads the results straight.

@MainActor
final class CarRig {
    /// Index of the rear wheels in `vehicle.wheels` (fronts are 0 and 1).
    private let driven: [Int]
    let spec: VehicleSpec
    let vehicle: SCNPhysicsVehicle
    let node: SCNNode
    private var shiftTimer = 0.0
    private(set) var gear = 0
    private(set) var rpm = 900.0
    private(set) var speedMps = 0.0

    private var mass: Double { spec.weightLb * 0.4536 }
    private var eta: Double { spec.drivetrain == .awd || spec.drivetrain == .fourWD ? 0.85 : spec.automatic ? 0.87 : 0.88 }
    private var shiftTime: Double { spec.automatic ? 0.12 : 0.2 }

    init(spec: VehicleSpec, paintHex: String?, at start: SCNVector3, heading: Float) {
        self.spec = spec
        switch spec.drivetrain {
        case .fwd: driven = [0, 1]
        case .awd, .fourWD: driven = [0, 1, 2, 3]
        case .rwd: driven = [2, 3]
        }

        // Chassis: a two-box coupe, heavy body down low.
        let massKg = spec.weightLb * 0.4536
        node = SCNNode()
        let body = SCNNode(geometry: SCNBox(width: 1.8, height: 0.55, length: 4.4, chamferRadius: 0.18))
        body.geometry?.firstMaterial?.diffuse.contents = CarRig.paint(paintHex)
        let cabin = SCNNode(geometry: SCNBox(width: 1.5, height: 0.45, length: 2.0, chamferRadius: 0.2))
        cabin.geometry?.firstMaterial?.diffuse.contents = UIColor(white: 0.12, alpha: 1)
        cabin.position = SCNVector3(0, 0.5, 0.15)
        node.addChildNode(body)
        node.addChildNode(cabin)
        let physics = SCNPhysicsBody(type: .dynamic, shape: SCNPhysicsShape(geometry: body.geometry!))
        physics.mass = CGFloat(massKg)
        physics.centerOfMassOffset = SCNVector3(0, -0.45, 0)
        physics.angularDamping = 0.95
        physics.friction = 0.6
        physics.restitution = 0
        physics.allowsResting = false
        node.physicsBody = physics
        node.position = start
        node.rotation = SCNVector4(0, 1, 0, heading)

        // Wheels: front pair steers; positions hang off the chassis in its frame.
        // Forward is -Z, so the fronts sit at negative z.
        let tire = UIColor(white: 0.07, alpha: 1)
        let r = CGFloat(spec.tireRadiusM)
        var wheels: [SCNPhysicsVehicleWheel] = []
        let anchors: [SIMD3<Float>] = [
            [-0.85, -0.1, -1.35], [0.85, -0.1, -1.35],
            [-0.85, -0.1, 1.35], [0.85, -0.1, 1.35],
        ]
        for a in anchors {
            let wn = SCNNode(geometry: SCNCylinder(radius: r, height: 0.24))
            wn.geometry?.firstMaterial?.diffuse.contents = tire
            wn.rotation = SCNVector4(0, 0, 1, CGFloat.pi / 2)
            wn.position = SCNVector3(a.x, a.y, a.z)
            let w = SCNPhysicsVehicleWheel(node: wn)
            w.radius = r
            w.suspensionRestLength = 0.38
            w.maximumSuspensionTravel = 0.25
            w.suspensionStiffness = 40
            w.suspensionCompression = 5
            w.suspensionDamping = 3.5
            w.maximumSuspensionForce = CGFloat(massKg * 12)
            w.frictionSlip = 1.0
            wheels.append(w)
        }
        vehicle = SCNPhysicsVehicle(chassisBody: physics, wheels: wheels)
    }

    /// One control frame. `throttle`/`brake` 0–1, `steer` −1…1.
    func drive(throttle: Double, brake: Double, steer: Double, dt: Double) {
        guard let body = node.physicsBody else { return }
        let v = body.velocity
        let speed = Double((v.x * v.x + v.z * v.z).squareRoot())
        speedMps = speed

        // Auto box: where the road speed puts the engine in the current gear.
        var ratio = spec.gearRatios[gear] * spec.finalDrive
        let wheelRpm = speed / spec.tireRadiusM * ratio * 60 / (2 * .pi)
        rpm = min(max(wheelRpm, 900), spec.redline * 1.02)
        if shiftTimer > 0 {
            shiftTimer -= dt
        } else if rpm > spec.redline * 0.97, gear < spec.gearRatios.count - 1 {
            gear += 1
            shiftTimer = shiftTime
        } else if rpm < spec.redline * 0.45, gear > 0, wheelRpm < spec.redline * 0.9 {
            gear -= 1
            shiftTimer = shiftTime
        }
        // Recompute after a possible shift so this frame's force uses the new gear.
        ratio = spec.gearRatios[gear] * spec.finalDrive

        // Engine: lb-ft → N m, through the box, onto the driven wheels.
        let shifting = shiftTimer > 0
        let tqNm = PerformanceModel.torque(at: rpm, spec: spec) * 1.3558 * throttle * (shifting ? 0 : 1)
        let force = tqNm * ratio * eta / spec.tireRadiusM
        let each = CGFloat(force / Double(driven.count))
        let stop = CGFloat(brake * mass * 9.81 * 0.8 / 4)
        for i in vehicle.wheels.indices {
            vehicle.applyEngineForce(driven.contains(i) ? each : 0, forWheelAt: i)
            vehicle.applyBrakingForce(stop, forWheelAt: i)
        }

        // Steering shrinks with speed: full lock only near walking pace.
        let lock = 0.6 - 0.42 * min(speed / 40, 1)
        let angle = CGFloat(steer * lock)
        vehicle.setSteeringAngle(angle, forWheelAt: 0)
        vehicle.setSteeringAngle(angle, forWheelAt: 1)
    }

    /// Back on the grid, standing still.
    func reset(to start: SCNVector3, heading: Float) {
        node.transform = SCNMatrix4MakeRotation(heading, 0, 1, 0)
        node.position = SCNVector3(start.x, 0.9, start.z)
        node.physicsBody?.resetTransform()
        node.physicsBody?.velocity = SCNVector3()
        node.physicsBody?.angularVelocity = SCNVector4()
        gear = 0
        shiftTimer = 0
    }

    private static func paint(_ hex: String?) -> UIColor {
        guard let hex else { return UIColor(red: 0.36, green: 0.38, blue: 0.4, alpha: 1) }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard let rgb = UInt32(digits, radix: 16) else { return UIColor(white: 0.36, alpha: 1) }
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
