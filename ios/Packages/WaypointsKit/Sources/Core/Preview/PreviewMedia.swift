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
        let paint = seedCar(for: path)?.colorHex.flatMap { UInt32($0.dropFirst(), radix: 16) }
            ?? paints[Int(seed % UInt64(paints.count))]
        try? jpeg(seed: seed, portrait: bucket == .posts, paint: paint).write(to: url, options: .atomic)
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

    static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha).cgColor
    }

    static func jpeg(seed: UInt64, portrait: Bool, paint: UInt32) -> Data {
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

            let shapes: [(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, roof: CGFloat)] = [
                (0.16, 0.38, 0.56, 0.70, 0.305), (0.14, 0.30, 0.58, 0.72, 0.325),
                (0.03, 0.10, 0.56, 0.72, 0.335), (0.02, 0.06, 0.60, 0.74, 0.33),
            ]
            let s = shapes[Int((seed >> 4) % 4)]
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

            let radius: CGFloat = 0.072
            let wheels = [p(0.2, radius), p(0.8, radius)]
            func disc(_ center: CGPoint, _ r: CGFloat, _ fill: CGColor) {
                ctx.setFillColor(fill)
                ctx.fillEllipse(in: CGRect(x: center.x - r * length, y: center.y - r * length, width: r * 2 * length, height: r * 2 * length))
            }
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
