import UIKit

enum PreviewMedia {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wp-preview-media-1", isDirectory: true)

    static func fileURL(bucket: MediaBucket, path: String) -> URL {
        let ext = (path as NSString).pathExtension
        return directory.appendingPathComponent("\(bucket.rawValue)-\(String(hash(path), radix: 16)).\(ext.isEmpty ? "jpg" : ext)")
    }

    static func url(bucket: MediaBucket, path: String) -> URL {
        let url = fileURL(bucket: bucket, path: path)
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seed = hash(path)
        let paints: [UInt32] = [0xB11226, 0x2B4C7E, 0xE2591B, 0xD8D8D4, 0x1F4E3D, 0xF2C230, 0x6E7377]
        let car = seedCar(for: path)
        let paint = car?.colorHex.flatMap { UInt32($0.dropFirst(), radix: 16) }
            ?? paints[Int(seed % UInt64(paints.count))]
        let part = seedListing(for: path).flatMap { $0.kind == .car ? nil : partGlyph($0.category, seed: seed) }
        try? jpeg(seed: seed, portrait: bucket == .posts, paint: paint,
                  shape: bodyShape(of: car, seed: seed), part: part).write(to: url, options: .atomic)
        return url
    }

    static func store(_ data: Data, bucket: MediaBucket, path: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(bucket: bucket, path: path), options: .atomic)
    }

    static func hash(_ string: String) -> UInt64 {
        string.utf8.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }

    static func seedCar(for path: String) -> Car? {
        let seed = PreviewSeed.self
        let id = seed.posts.first { $0.posterPath == path || $0.photoPaths.contains(path) }?.carID
            ?? seed.listings.first { listing in listing.photos.contains { $0.path == path } }?.carID
        return seed.cars.first { $0.id == id || path.contains("/\($0.id)/") }
    }

    static func seedListing(for path: String) -> Listing? {
        PreviewSeed.listings.first { listing in listing.photos.contains { $0.path == path } }
    }

    /// `MapGlyph` vehicle name → index into `shapes` in `jpeg`:
    /// 0 fastback/coupe, 1 notchback sedan, 2 long-roof hatch/wagon, 3 upright truck/van.
    static let bodyShapes: [String: Int] = [
        "coupe": 0, "pony": 0, "roadster": 0, "supercar": 0, "drift": 0, "time_attack": 0,
        "targa": 0, "shooting_brake": 0, "fastback_classic": 0, "wide_body": 0, "hot_rod": 0,
        "rat_rod": 0, "sport_bike": 0, "cruiser_bike": 0,
        "sedan": 1, "muscle": 1, "classic": 1, "restomod": 1, "lowrider": 1, "safety_car": 1,
        "hatch": 2, "wagon": 2, "rally": 2, "suv": 2, "gt_wing_hatch": 2, "woody_wagon": 2,
        "microcar": 2, "ute": 2,
        "kei": 3, "pickup": 3, "lifted_truck": 3, "dually": 3, "van": 3, "van_camper": 3,
        "box_truck": 3, "flatbed": 3,
    ]

    /// The drawn body follows the car's glyph (`PreviewSeed.bodies`, else the owner's marker
    /// icon, else the app's "coupe" default); unknown paths keep the old hash pick.
    static func bodyShape(of car: Car?, seed: UInt64) -> Int {
        guard let car else { return Int((seed >> 4) % 4) }
        let glyph = PreviewSeed.bodies[car.id]
            ?? PreviewSeed.profiles.first { $0.userID == car.ownerID }?.markerIcon
        return glyph.flatMap { bodyShapes[$0] } ?? 0
    }

    enum PartArt {
        case wheel, exhaust, turbo, seat, steeringWheel, coilover, block, ecu, wing
    }

    /// Part listings (and wanted ads) draw a part, not a car.
    static func partGlyph(_ category: ListingCategory?, seed: UInt64) -> PartArt {
        switch category {
        case .wheelsTires, .brakes: return .wheel
        case .suspension: return .coilover
        case .exhaust: return .exhaust
        case .intakeFuel, .forcedInduction: return .turbo
        case .interior: return (seed >> 4) & 1 == 0 ? .seat : .steeringWheel
        case .exteriorAero: return .wing
        case .lighting, .electronicsTuning, .tools: return .ecu
        case .engine, .drivetrain, .apparel, .other, nil: return .block
        }
    }

    static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha).cgColor
    }

    static func jpeg(seed: UInt64, portrait: Bool, paint: UInt32, shape: Int, part: PartArt?) -> Data {
        let size = portrait ? CGSize(width: 720, height: 1280) : CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            let ctx = context.cgContext
            let w = size.width, h = size.height
            let ground = h * (portrait ? 0.6 : 0.68)
            let length = w * (portrait ? 0.86 : 0.72)
            let left = (w - length) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: left + x * length, y: ground - y * length) }

            let walls: [UInt32] = [0x15161A, 0x1A1816, 0x13171A, 0x18191B]
            ctx.setFillColor(color(walls[Int((seed >> 8) % 4)]))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(color(0x232325))
            ctx.fill(CGRect(x: 0, y: ground - length * 0.02, width: w, height: h))
            let lampX = w * ((seed >> 12) % 2 == 0 ? 0.1 : 0.9)
            let lamp = CGPoint(x: lampX, y: ground - length * 0.52)
            ctx.setStrokeColor(color(0x3A3A3E))
            ctx.setLineWidth(length * 0.012)
            ctx.move(to: CGPoint(x: lampX, y: ground - length * 0.02))
            ctx.addLine(to: lamp)
            ctx.strokePath()
            if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [color(0xFFB224, 0.34), color(0xFFB224, 0)] as CFArray, locations: [0, 1]) {
                ctx.drawRadialGradient(glow, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: w * 0.8, options: [])
            }
            ctx.setFillColor(color(0xFFD27A))
            ctx.fillEllipse(in: CGRect(x: lampX - length * 0.02, y: lamp.y - length * 0.012, width: length * 0.04, height: length * 0.024))

            ctx.setStrokeColor(color(0xF3F1EC, 0.14))
            ctx.setLineWidth(length * 0.01)
            let offset = CGFloat((seed >> 16) % 100) / 100 * w / 3
            for i in -1..<4 {
                let x = offset + CGFloat(i) * w / 3
                ctx.move(to: CGPoint(x: x, y: ground + length * 0.03))
                ctx.addLine(to: CGPoint(x: x - (h - ground) * 0.5, y: h))
            }
            ctx.strokePath()
            ctx.setFillColor(color(0x000000, 0.5))
            ctx.fillEllipse(in: CGRect(x: left + length * 0.01, y: ground - length * 0.014, width: length * 0.98, height: length * 0.045))

            let radius: CGFloat = 0.072
            func disc(_ center: CGPoint, _ r: CGFloat, _ fill: CGColor) {
                ctx.setFillColor(fill)
                ctx.fillEllipse(in: CGRect(x: center.x - r * length, y: center.y - r * length, width: r * 2 * length, height: r * 2 * length))
            }
            func bar(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat, _ fill: CGColor) {
                let a = p(x0, y0), b = p(x1, y1)
                ctx.setFillColor(fill)
                ctx.addPath(CGPath(roundedRect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                                       width: abs(b.x - a.x), height: abs(b.y - a.y)),
                                   cornerWidth: r * length, cornerHeight: r * length, transform: nil))
                ctx.fillPath()
            }
            func drawPart(_ kind: PartArt) {
                switch kind {
                case .wheel:
                    let rear = p(0.63, 0.135), front = p(0.4, 0.165)
                    disc(rear, 0.135, color(0x0B0B0C))
                    disc(rear, 0.086, color(0x8E8C88))
                    disc(rear, 0.028, color(0x1A1A1C))
                    disc(front, 0.165, color(0x0B0B0C))
                    disc(front, 0.105, color(0x8E8C88))
                    for i in 0..<5 {
                        let t = CGFloat(i) * 2 * .pi / 5 - .pi / 2
                        disc(CGPoint(x: front.x + cos(t) * 0.062 * length, y: front.y + sin(t) * 0.062 * length),
                             0.012, color(0x1A1A1C))
                    }
                    disc(front, 0.032, color(0x1A1A1C))
                case .exhaust:
                    ctx.setFillColor(color(0x8E8C88))
                    ctx.fillEllipse(in: CGRect(x: left + length * 0.4, y: p(0.4, 0.245).y,
                                               width: length * 0.36, height: length * 0.175))
                    bar(0.5, 0.07, 0.54, 0.245, 0.012, color(0x6E7377))
                    bar(0.12, 0.125, 0.42, 0.17, 0.021, color(0x8E8C88))
                    bar(0.12, 0.055, 0.42, 0.095, 0.017, color(0x8E8C88))
                    bar(0.74, 0.105, 0.88, 0.14, 0.015, color(0x8E8C88))
                    disc(p(0.88, 0.1225), 0.02, color(0x0B0B0C))
                case .turbo:
                    bar(0.5, 0.085, 0.72, 0.135, 0.022, color(0x8E8C88))
                    bar(0.68, 0.045, 0.74, 0.135, 0.02, color(0x8E8C88))
                    let c = p(0.45, 0.155)
                    disc(c, 0.135, color(0x8E8C88))
                    disc(c, 0.09, color(0x1A1A1C))
                    disc(c, 0.045, color(0x8E8C88))
                    disc(c, 0.017, color(0x1A1A1C))
                    bar(0.39, 0.27, 0.49, 0.31, 0.018, color(0x8E8C88))
                    bar(0.37, 0.26, 0.41, 0.32, 0.011, color(0x6E7377))
                case .seat:
                    bar(0.32, 0.02, 0.68, 0.045, 0.01, color(0x6E7377))
                    bar(0.3, 0.045, 0.72, 0.115, 0.03, color(0x0E1114))
                    let back = CGMutablePath()
                    back.move(to: p(0.3, 0.045))
                    back.addLine(to: p(0.45, 0.045))
                    back.addLine(to: p(0.4, 0.13))
                    back.addQuadCurve(to: p(0.3, 0.3), control: p(0.35, 0.25))
                    back.addLine(to: p(0.22, 0.3))
                    back.addQuadCurve(to: p(0.3, 0.115), control: p(0.26, 0.22))
                    back.closeSubpath()
                    ctx.addPath(back)
                    ctx.setFillColor(color(0x0E1114))
                    ctx.fillPath()
                    bar(0.22, 0.26, 0.31, 0.305, 0.02, color(0x1A1A1C))
                    bar(0.335, 0.13, 0.365, 0.27, 0.007, color(paint))
                case .steeringWheel:
                    let hub = p(0.5, 0.18)
                    ctx.setStrokeColor(color(0x0B0B0C))
                    ctx.setLineWidth(length * 0.036)
                    ctx.strokeEllipse(in: CGRect(x: hub.x - 0.135 * length, y: hub.y - 0.135 * length,
                                                 width: 0.27 * length, height: 0.27 * length))
                    bar(0.365, 0.16, 0.465, 0.195, 0.011, color(0x1A1A1C))
                    bar(0.535, 0.16, 0.635, 0.195, 0.011, color(0x1A1A1C))
                    bar(0.48, 0.045, 0.52, 0.165, 0.011, color(0x1A1A1C))
                    disc(hub, 0.046, color(0x1A1A1C))
                    disc(hub, 0.02, color(0x8E8C88))
                case .coilover:
                    bar(0.455, 0.045, 0.545, 0.3, 0.018, color(0x1A1A1C))
                    for i in 0..<5 {
                        let y = 0.075 + CGFloat(i) * 0.033
                        bar(0.41, y, 0.59, y + 0.021, 0.009, color(paint))
                    }
                    bar(0.43, 0.3, 0.57, 0.335, 0.013, color(0x8E8C88))
                    bar(0.48, 0.335, 0.52, 0.365, 0.009, color(0x1A1A1C))
                    bar(0.42, 0.02, 0.58, 0.045, 0.011, color(0x8E8C88))
                case .block:
                    bar(0.28, 0.045, 0.7, 0.21, 0.022, color(0x1A1A1C))
                    bar(0.34, 0.21, 0.6, 0.27, 0.018, color(0x8E8C88))
                    for i in 0..<4 {
                        bar(0.35 + CGFloat(i) * 0.07, 0.27, 0.39 + CGFloat(i) * 0.07, 0.295, 0.009, color(paint))
                    }
                    bar(0.7, 0.095, 0.78, 0.17, 0.014, color(0x8E8C88))
                    bar(0.24, 0.085, 0.28, 0.165, 0.011, color(0x6E7377))
                    for i in 0..<4 {
                        bar(0.32 + CGFloat(i) * 0.09, 0.045, 0.36 + CGFloat(i) * 0.09, 0.065, 0.007, color(0x0B0B0C))
                    }
                case .ecu:
                    bar(0.34, 0.05, 0.66, 0.23, 0.026, color(0x1A1A1C))
                    bar(0.38, 0.11, 0.52, 0.2, 0.013, color(0x0B0B0C))
                    disc(p(0.6, 0.155), 0.014, color(paint))
                    for i in 0..<4 {
                        bar(0.36 + CGFloat(i) * 0.08, 0.23, 0.395 + CGFloat(i) * 0.08, 0.265, 0.006, color(0x8E8C88))
                    }
                case .wing:
                    bar(0.28, 0.045, 0.34, 0.235, 0.013, color(0x1A1A1C))
                    bar(0.66, 0.045, 0.72, 0.235, 0.013, color(0x1A1A1C))
                    bar(0.18, 0.235, 0.82, 0.28, 0.02, color(0x0E1114))
                    bar(0.15, 0.215, 0.21, 0.315, 0.011, color(0x0E1114))
                    bar(0.79, 0.215, 0.85, 0.315, 0.011, color(0x0E1114))
                }
            }

            if let part {
                ctx.setFillColor(color(0x000000, 0.5))
                ctx.fillEllipse(in: CGRect(x: left + length * 0.26, y: ground - length * 0.014,
                                           width: length * 0.48, height: length * 0.045))
                drawPart(part)
                return
            }

            let shapes: [(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, roof: CGFloat)] = [
                (0.16, 0.38, 0.56, 0.70, 0.305), (0.14, 0.30, 0.58, 0.72, 0.325),
                (0.03, 0.10, 0.56, 0.72, 0.335), (0.02, 0.06, 0.60, 0.74, 0.33),
            ]
            let s = shapes[shape]
            let belt: CGFloat = 0.222
            let body = CGMutablePath()
            body.move(to: p(0.02, 0.05))
            body.addLine(to: p(0.012, 0.17))
            body.addQuadCurve(to: p(s.a, belt), control: p(0.012, 0.22))
            body.addQuadCurve(to: p(s.b, s.roof), control: p((s.a + s.b) / 2 - 0.02, (belt + s.roof) / 2 + 0.03))
            body.addQuadCurve(to: p(s.c, s.roof - 0.005), control: p((s.b + s.c) / 2, s.roof + 0.012))
            body.addQuadCurve(to: p(s.d, 0.21), control: p((s.c + s.d) / 2 + 0.01, (s.roof + 0.21) / 2 + 0.02))
            body.addQuadCurve(to: p(0.95, 0.165), control: p(0.85, 0.2))
            body.addQuadCurve(to: p(0.992, 0.09), control: p(0.996, 0.15))
            body.addLine(to: p(0.985, 0.05))
            body.closeSubpath()
            ctx.addPath(body)
            ctx.setFillColor(color(paint))
            ctx.fillPath()

            let wheels = [p(0.2, radius), p(0.8, radius)]
            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.setFillColor(color(0x000000, 0.28))
            ctx.fill(CGRect(x: left, y: ground - length * 0.1, width: length, height: length * 0.1))
            ctx.setStrokeColor(color(0xFFFFFF, 0.14))
            ctx.setLineWidth(length * 0.006)
            ctx.move(to: p(0.02, 0.172))
            ctx.addLine(to: p(0.96, 0.166))
            ctx.strokePath()
            for wheel in wheels { disc(wheel, radius + 0.018, color(0x08080A)) }
            ctx.restoreGState()

            ctx.move(to: p(s.a + 0.04, belt))
            ctx.addLine(to: p(s.b + 0.012, s.roof - 0.02))
            ctx.addLine(to: p(s.c - 0.004, s.roof - 0.022))
            ctx.addLine(to: p(s.d - 0.035, belt))
            ctx.closePath()
            ctx.setFillColor(color(0x0E1114))
            ctx.fillPath()
            ctx.setStrokeColor(color(paint))
            ctx.setLineWidth(length * 0.014)
            ctx.move(to: p((s.b + s.c) / 2 + 0.02, belt))
            ctx.addLine(to: p((s.b + s.c) / 2 + 0.01, s.roof - 0.01))
            ctx.strokePath()
            ctx.setFillColor(color(0xF3F1EC))
            ctx.fill(CGRect(origin: p(0.955, 0.152), size: CGSize(width: length * 0.03, height: length * 0.016)))
            ctx.setFillColor(color(0xFF4B3A))
            ctx.fill(CGRect(origin: p(0.013, 0.168), size: CGSize(width: length * 0.02, height: length * 0.02)))
            for wheel in wheels {
                disc(wheel, radius, color(0x0B0B0C))
                disc(wheel, radius * 0.62, color(0x8E8C88))
                disc(wheel, radius * 0.2, color(0x1A1A1C))
            }
        }
    }
}
