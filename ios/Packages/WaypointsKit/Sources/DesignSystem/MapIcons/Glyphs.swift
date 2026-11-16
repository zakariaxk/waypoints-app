import SwiftUI

// Report glyphs and meet-pin marks (plan 9.8): custom drawings on the same 24 × 24 grid as
// the silhouettes. Closed subpaths are filled, open subpaths stroked with round caps.

/// One mark: `fill` is painted solid (`evenOdd` punches holes like the camera lens),
/// `stroke` is stroked at `line` points with round caps and joins.
struct GlyphDrawing {
    var fill = Path()
    var stroke = Path()
    var evenOdd = false
    var line: CGFloat = 0
}

enum GlyphArt {
    /// A rounded bar rotated about a point — the brick the filled marks are built from.
    private static func bar(_ w: CGFloat, _ h: CGFloat, at c: CGPoint, angle: CGFloat = 0) -> Path {
        Path(roundedRect: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), cornerRadius: h / 2)
            .applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
                .translatedBy(x: -c.x, y: -c.y))
    }

    static func report(_ kind: String, in r: CGRect) -> GlyphDrawing {
        let u = min(r.width, r.height) / 24
        func pt(_ gx: CGFloat, _ gy: CGFloat) -> CGPoint { CGPoint(x: r.minX + gx * u, y: r.minY + gy * u) }
        func rect(_ gx: CGFloat, _ gy: CGFloat, _ gw: CGFloat, _ gh: CGFloat) -> CGRect {
            CGRect(x: r.minX + gx * u, y: r.minY + gy * u, width: gw * u, height: gh * u)
        }
        var d = GlyphDrawing()
        d.line = 2.3 * u
        switch kind {
        case "closure":
            d.fill.addPath(bar(13 * u, 3 * u, at: pt(12, 12), angle: .pi / 4))
            d.fill.addPath(bar(13 * u, 3 * u, at: pt(12, 12), angle: -.pi / 4))
        case "pothole":
            // The dip that pairs with speed_bump's hump.
            var p = Path()
            p.move(to: pt(4, 9.5))
            p.addLine(to: pt(9, 9.5))
            p.addCurve(to: pt(15, 9.5), control1: pt(10.5, 19), control2: pt(13.5, 19))
            p.addLine(to: pt(20, 9.5))
            d.stroke.addPath(p)
        case "speed_bump":
            var p = Path()
            p.move(to: pt(4, 15))
            p.addLine(to: pt(8.5, 15))
            p.addCurve(to: pt(15.5, 15), control1: pt(10, 7.5), control2: pt(14, 7.5))
            p.addLine(to: pt(20, 15))
            d.stroke.addPath(p)
        case "steep_entrance":
            var p = Path()
            p.move(to: pt(4, 16.5))
            p.addLine(to: pt(9.5, 16.5))
            p.addLine(to: pt(19.5, 7.5))
            d.stroke.addPath(p)
        case "rough_road":
            var p = Path()
            p.move(to: pt(4, 12))
            p.addCurve(to: pt(9.3, 12), control1: pt(5.5, 7.5), control2: pt(7.7, 7.5))
            p.addCurve(to: pt(14.7, 12), control1: pt(11, 16.5), control2: pt(13, 16.5))
            p.addCurve(to: pt(20, 12), control1: pt(16.3, 7.5), control2: pt(18.4, 7.5))
            d.stroke.addPath(p)
        case "police":
            var p = Path()
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let radius: CGFloat = i.isMultiple(of: 2) ? 7.3 * u : 3.1 * u
                let point = CGPoint(x: pt(12, 12).x + cos(a) * radius, y: pt(12, 12).y + sin(a) * radius)
                if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
            }
            p.closeSubpath()
            d.fill.addPath(p)
        case "speed_camera", "red_light_camera":
            d.evenOdd = true
            d.fill.addRoundedRect(in: rect(5, 8.5, 14, 9), cornerSize: CGSize(width: 1.6 * u, height: 1.6 * u))
            d.fill.addRect(rect(10, 5.5, 4, 2.5))
            d.fill.addEllipse(in: rect(9.5, 10.5, 5, 5))
        case "fuel_e85":
            d.evenOdd = true
            d.fill.addRoundedRect(in: rect(5.5, 5, 8.5, 14), cornerSize: CGSize(width: 1.4 * u, height: 1.4 * u))
            d.fill.addRect(rect(7.5, 7.5, 4.5, 4))
            d.fill.addPath(bar(6 * u, 2 * u, at: pt(15.8, 9), angle: -.pi / 5))
        case "help":
            // A raised hand: palm, three fingers, thumb.
            d.fill.addRoundedRect(in: rect(8, 10.5, 8, 9), cornerSize: CGSize(width: 2.5 * u, height: 2.5 * u))
            for fx in [9.3, 11.9, 14.5] as [CGFloat] {
                d.fill.addRoundedRect(in: rect(fx - 1.1, 4.3, 2.2, 6.5), cornerSize: CGSize(width: 1.1 * u, height: 1.1 * u))
            }
            d.fill.addPath(bar(5.5 * u, 2.2 * u, at: pt(7.3, 14.8), angle: -.pi / 4))
        default:
            // "hazard" and anything unknown: the exclamation.
            d.fill.addRoundedRect(in: rect(10.4, 4, 3.2, 9.5), cornerSize: CGSize(width: 1.6 * u, height: 1.6 * u))
            d.fill.addEllipse(in: rect(10.3, 16.2, 3.4, 3.4))
        }
        return d
    }

    static func meet(_ kind: String, in r: CGRect) -> GlyphDrawing {
        let u = min(r.width, r.height) / 24
        func pt(_ gx: CGFloat, _ gy: CGFloat) -> CGPoint { CGPoint(x: r.minX + gx * u, y: r.minY + gy * u) }
        func rect(_ gx: CGFloat, _ gy: CGFloat, _ gw: CGFloat, _ gh: CGFloat) -> CGRect {
            CGRect(x: r.minX + gx * u, y: r.minY + gy * u, width: gw * u, height: gh * u)
        }
        var d = GlyphDrawing()
        d.line = 2.6 * u
        switch kind {
        case "cruise":
            // A road bending away: straight, quarter turn, straight.
            var p = Path()
            p.move(to: pt(4.5, 19))
            p.addLine(to: pt(9, 19))
            p.addQuadCurve(to: pt(19, 9), control: pt(19, 19))
            p.addLine(to: pt(19, 4.5))
            d.stroke.addPath(p)
        case "hangout":
            // A cup: tapered body, handle arc, saucer.
            var cup = Path()
            cup.move(to: pt(8, 7.5))
            cup.addLine(to: pt(15.5, 7.5))
            cup.addLine(to: pt(14.7, 15.5))
            cup.addLine(to: pt(8.8, 15.5))
            cup.closeSubpath()
            d.fill.addPath(cup)
            d.fill.addRoundedRect(in: rect(5.5, 17, 13.5, 1.8), cornerSize: CGSize(width: 0.9 * u, height: 0.9 * u))
            var handle = Path()
            handle.addArc(center: pt(15.9, 11.3), radius: 2.2 * u,
                          startAngle: .degrees(-80), endAngle: .degrees(80), clockwise: false)
            d.stroke.addPath(handle)
            d.line = 1.7 * u
        case "track_day":
            // A chicane: one hard S.
            var p = Path()
            p.move(to: pt(6.5, 6))
            p.addCurve(to: pt(17.5, 18), control1: pt(17.5, 6), control2: pt(6.5, 18))
            d.stroke.addPath(p)
            d.line = 2.8 * u
        case "show":
            // A rosette: eight petals, center, two ribbons.
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                d.fill.addPath(bar(3.8 * u, 2.1 * u,
                                   at: CGPoint(x: pt(12, 0).x + cos(a) * 4.3 * u, y: pt(0, 10.5).y + sin(a) * 4.3 * u),
                                   angle: a))
            }
            d.fill.addEllipse(in: rect(9.6, 8.1, 4.8, 4.8))
            d.fill.addPath(bar(2.2 * u, 6.5 * u, at: pt(10, 17.2), angle: .pi / 12))
            d.fill.addPath(bar(2.2 * u, 6.5 * u, at: pt(14, 17.2), angle: -.pi / 12))
        default:
            // "meet": three coupe silhouettes nose-in.
            for k in 0..<3 {
                let phi = -CGFloat.pi / 2 + CGFloat(k) * 2 * .pi / 3
                let pos = CGPoint(x: pt(12, 0).x + cos(phi) * 5.4 * u, y: pt(0, 12).y + sin(phi) * 5.4 * u)
                let car = VehicleSilhouette("coupe")
                    .path(in: CGRect(x: pos.x - 4.3 * u, y: pos.y - 4.3 * u, width: 8.6 * u, height: 8.6 * u))
                d.fill.addPath(car.applying(CGAffineTransform(translationX: pos.x, y: pos.y)
                    .rotated(by: phi - .pi / 2).translatedBy(x: -pos.x, y: -pos.y)))
            }
        }
        return d
    }
}

/// The custom mark inside `ReportBadge` (plan 9.8). Ink is the badge's glyph color.
public struct ReportGlyph: View {
    let kind: String
    let paint: Color
    public init(kind: String, paint: Color = .chalk) { self.kind = kind; self.paint = paint }

    public var body: some View {
        GeometryReader { proxy in
            let d = GlyphArt.report(kind, in: CGRect(origin: .zero, size: proxy.size))
            ZStack {
                d.fill.fill(paint, style: FillStyle(eoFill: d.evenOdd))
                d.stroke.stroke(paint, style: StrokeStyle(lineWidth: d.line, lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// The custom mark inside `MeetPin` (plan 9.8): three cars nose-in, a curved road, a cup,
/// a chicane, or a rosette.
public struct MeetGlyph: View {
    let kind: String
    let paint: Color
    public init(kind: String, paint: Color = .sodium) { self.kind = kind; self.paint = paint }

    public var body: some View {
        GeometryReader { proxy in
            let d = GlyphArt.meet(kind, in: CGRect(origin: .zero, size: proxy.size))
            ZStack {
                d.fill.fill(paint, style: FillStyle(eoFill: d.evenOdd))
                d.stroke.stroke(paint, style: StrokeStyle(lineWidth: d.line, lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

#Preview("Glyphs") {
    VStack(spacing: Space.s24) {
        HStack(spacing: Space.s12) {
            ForEach(["speed_bump", "steep_entrance", "pothole", "rough_road", "police", "hazard",
                     "closure", "fuel_e85", "speed_camera", "red_light_camera", "help"], id: \.self) {
                ReportGlyph(kind: $0, paint: .chalk).frame(width: 24, height: 24)
            }
        }
        HStack(spacing: Space.s12) {
            ForEach(["meet", "cruise", "hangout", "track_day", "show"], id: \.self) {
                MeetGlyph(kind: $0).frame(width: 24, height: 24)
            }
        }
    }
    .padding()
    .background(Color.asphalt)
    .preferredColorScheme(.dark)
}
