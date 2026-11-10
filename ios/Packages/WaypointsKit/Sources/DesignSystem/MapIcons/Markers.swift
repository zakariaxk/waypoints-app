import SwiftUI

// VehicleMarker, report badges, meet pins, and the cluster (plan 9.8).

/// How a vehicle marker is drawn.
public enum MarkerRole: Sendable, Hashable {
    case you
    case friend(name: String)
    case approximate
    case stranger
}

public struct VehicleMarker: View {
    let icon: String
    let paint: Color
    let role: MarkerRole
    let heading: Double?
    let moving: Bool
    let staleness: TimeInterval
    let selected: Bool
    let trail: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(icon: String, paint: Color, role: MarkerRole, heading: Double? = nil, moving: Bool = false,
                staleness: TimeInterval = 0, selected: Bool = false, trail: String? = nil) {
        self.icon = icon; self.paint = paint; self.role = role; self.heading = heading; self.moving = moving
        self.staleness = staleness; self.selected = selected; self.trail = trail
    }

    private var size: CGFloat {
        switch role {
        case .you: Size.Marker.you
        case .friend, .approximate: Size.Marker.friend
        case .stranger: Size.Marker.stranger
        }
    }

    private var rotates: Bool {
        switch role {
        case .you, .friend: true
        case .approximate, .stranger: false
        }
    }

    public var body: some View {
        VStack(spacing: Space.s2) {
            ZStack {
                if case .approximate = role {
                    Circle()
                        .strokeBorder(Color.xenon, style: StrokeStyle(lineWidth: Size.Marker.ring, dash: [4, 3]))
                        .frame(width: Size.Marker.approximateRing, height: Size.Marker.approximateRing)
                }
                if case .friend = role, moving, staleness < 60 {
                    Circle()
                        .stroke(Color.go, lineWidth: Size.Marker.ring)
                        .frame(width: size, height: size)
                        .scaleEffect(pulse ? 1.35 : 1)
                        .opacity(pulse ? 0 : 1)
                }
                if case .you = role {
                    Circle().stroke(Color.sodium, lineWidth: Size.Marker.ring).frame(width: size, height: size)
                }
                silhouette
                    .rotationEffect(.degrees(rotates ? (heading ?? 0) : 0))
            }
            .frame(width: max(size, Size.hitTarget), height: max(size, Size.hitTarget))
            if case let .friend(name) = role, !name.isEmpty {
                Text(verbatim: staleness >= 300 ? "\(name) · \(Int(staleness / 60))\(thinSpace)m" : name)
                    .typeStyle(.readoutS)
                    .foregroundStyle(Color.chalk)
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
                    .background(Color.tarmac, in: Capsule())
            }
        }
        .saturation(staleness >= 300 ? 1 - Opacity.staleDesaturation : 1)
        .scaleEffect(selected ? Size.Marker.selectedScale : 1)
        .motion(.sheet, value: selected)
        .mapShadow()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: Timing.livePulse).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibility))
    }

    private var accessibility: String {
        switch role {
        case .you: "You"
        case let .friend(name): moving ? "\(name), moving" : name
        case .approximate: "Approximate location"
        case .stranger: "A driver nearby"
        }
    }

    @ViewBuilder private var silhouette: some View {
        let shape = VehicleSilhouette(icon)
        let inner = size * 0.82
        switch role {
        case .stranger:
            shape.fill(Color.dust).frame(width: inner, height: inner)
        case .approximate:
            shape.fill(paint).frame(width: inner, height: inner).opacity(Opacity.approximate)
        case .you, .friend:
            shape.fill(paint)
                .overlay(shape.stroke(Color.chalk.opacity(0.7), lineWidth: Size.Marker.innerStroke))
                .background(shape.stroke(Color.asphalt, lineWidth: Size.Marker.keyline * 2))
                .frame(width: inner, height: inner)
        }
    }
}

/// A silhouette at any size, for palettes and inline badges.
public struct SilhouetteIcon: View {
    let name: String
    let paint: Color
    public init(_ name: String, paint: Color) { self.name = name; self.paint = paint }
    public var body: some View {
        VehicleSilhouette(name).fill(paint).aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

/// Report badge: shape encodes severity so color is not the only signal.
public struct ReportBadge: View {
    let kind: String
    public init(kind: String) { self.kind = kind }

    private var symbol: String {
        switch kind {
        case "speed_bump": "chevron.compact.up"
        case "steep_entrance": "arrow.up.right"
        case "pothole": "circle.dotted"
        case "rough_road": "water.waves"
        case "police": "shield"
        case "hazard": "exclamationmark"
        case "closure": "xmark"
        case "fuel_e85": "fuelpump"
        default: "mappin"
        }
    }

    public var body: some View {
        let s = Size.Marker.reportBadge
        ZStack {
            switch kind {
            case "hazard", "closure", "pothole":
                RoundedRectangle(cornerRadius: Radius.r6).fill(Color.brake).frame(width: s * 0.74, height: s * 0.74)
                    .rotationEffect(.degrees(45))
            case "police":
                RoundedRectangle(cornerRadius: Radius.r6).fill(Color.xenon).frame(width: s, height: s)
            case "fuel_e85":
                Circle().fill(Color.go).frame(width: s, height: s)
            default:
                Circle().fill(Color.tarmac).frame(width: s, height: s)
                    .overlay(Circle().strokeBorder(Color.sodium, lineWidth: Size.Marker.ring))
            }
            Image(systemName: symbol)
                .font(.system(size: Size.Marker.reportGlyph * 0.55, weight: .bold))
                .foregroundStyle(["speed_bump", "steep_entrance", "rough_road"].contains(kind) ? Color.sodium : Color.asphalt)
        }
        .frame(width: Size.hitTarget, height: Size.hitTarget)
        .mapShadow()
        .accessibilityLabel(Text(MapIconSet.title(kind)))
    }
}

/// Meet pin: a tarmac rounded square with a glyph per kind and the start time below.
public struct MeetPin: View {
    let kind: String
    let time: String?
    let live: Bool
    public init(kind: String, time: String? = nil, live: Bool = false) { self.kind = kind; self.time = time; self.live = live }

    private var symbol: String {
        switch kind {
        case "cruise": "road.lanes.curved.right"
        case "hangout": "cup.and.saucer"
        case "track_day": "flag.checkered"
        case "show": "rosette"
        default: "car.2"
        }
    }

    public var body: some View {
        VStack(spacing: Space.s2) {
            Image(systemName: symbol)
                .font(.system(size: Size.Marker.meetPin * 0.42, weight: .semibold))
                .foregroundStyle(Color.sodium)
                .frame(width: Size.Marker.meetPin, height: Size.Marker.meetPin)
                .background(Color.tarmac, in: RoundedRectangle(cornerRadius: Radius.r12))
                .overlay(RoundedRectangle(cornerRadius: Radius.r12).strokeBorder(live ? Color.go : Color.seam, lineWidth: Size.Marker.ring))
            if let time {
                Text(verbatim: time).typeStyle(.readoutS).foregroundStyle(Color.chalk)
                    .padding(.horizontal, Space.s4).background(Color.tarmac, in: Capsule())
            }
        }
        .mapShadow()
    }
}

/// Cluster: a tarmac circle with a count.
public struct ClusterMarker: View {
    let count: Int
    public init(count: Int) { self.count = count }
    public var body: some View {
        Text(verbatim: "\(count)")
            .typeStyle(.readoutM)
            .foregroundStyle(Color.chalk)
            .frame(width: Size.Marker.cluster, height: Size.Marker.cluster)
            .background(Color.tarmac, in: Circle())
            .overlay(Circle().strokeBorder(Color.seam, lineWidth: Size.Marker.innerStroke))
            .mapShadow()
            .accessibilityLabel(Text("\(count) drivers"))
    }
}

/// The standard inline mention of a car: silhouette in paint color plus "2019 Mustang GT".
public struct CarBadge: View {
    let label: String
    let icon: String
    let paint: Color
    public init(_ label: String, icon: String = "coupe", paint: Color = .dust) {
        self.label = label; self.icon = icon; self.paint = paint
    }
    public var body: some View {
        HStack(spacing: Space.s4) {
            SilhouetteIcon(icon, paint: paint).frame(width: Size.inlineSilhouette, height: Size.inlineSilhouette)
            Text(verbatim: label).typeStyle(.sub).foregroundStyle(Color.dust).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Markers") {
    HStack(spacing: Space.s24) {
        VehicleMarker(icon: "pony", paint: Color(rgb: 0x1F6FD1), role: .you, heading: 30)
        VehicleMarker(icon: "suv", paint: Color(rgb: 0xC0392B), role: .friend(name: "Devon"), moving: true)
        VehicleMarker(icon: "hatch", paint: Color(rgb: 0xE5E5E5), role: .approximate)
        VehicleMarker(icon: "coupe", paint: .dust, role: .stranger)
        ReportBadge(kind: "speed_bump")
        MeetPin(kind: "meet", time: "8:00")
        ClusterMarker(count: 12)
    }
    .padding()
    .background(Color.asphalt)
}
