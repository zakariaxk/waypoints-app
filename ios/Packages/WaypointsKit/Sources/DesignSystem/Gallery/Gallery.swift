import SwiftUI

/// Every token and component (plan 9.9), with a contrast audit of text-on-surface pairs.
/// Reachable from Settings in debug builds.
public struct Gallery: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(verbatim: "COLOR")
                ForEach(Palette.all) { token in
                    Row(Text(verbatim: token.name), subtitle: Text(verbatim: token.hex), leading: {
                        RoundedRectangle(cornerRadius: Radius.r6).fill(token.color)
                            .frame(width: Size.hitTarget, height: Size.hitTarget)
                            .overlay(RoundedRectangle(cornerRadius: Radius.r6).strokeBorder(Color.seam))
                    })
                }
                SectionLabel(verbatim: "CONTRAST")
                ForEach(Contrast.pairs, id: \.label) { pair in
                    Row(Text(verbatim: pair.label), trailing: {
                        Text(readout: "\(Format.number(pair.ratio, fractionDigits: 1)):1 \(pair.ratio >= pair.minimum ? "pass" : "FAIL")", token: .readoutS)
                            .foregroundStyle(pair.ratio >= pair.minimum ? Color.go : Color.brake)
                    })
                }
                SectionLabel(verbatim: "TYPE")
                ForEach(TypeToken.allCases) { t in
                    Text(verbatim: t.isReadout ? "2019 · 486 hp" : "Cars and Coffee \(t.rawValue)")
                        .typeStyle(t).foregroundStyle(Color.chalk)
                        .padding(.horizontal, Space.margin).padding(.vertical, Space.s4)
                }
                SectionLabel(verbatim: "SPACE AND RADIUS")
                HStack(alignment: .bottom, spacing: Space.s8) {
                    ForEach(Space.all, id: \.0) { name, v in
                        VStack { Rectangle().fill(Color.sodium).frame(width: v, height: v); Text(verbatim: name).typeStyle(.readoutS) }
                    }
                }
                .padding(.horizontal, Space.margin)
                HStack(spacing: Space.s12) {
                    ForEach(Radius.all, id: \.0) { name, r in
                        RoundedRectangle(cornerRadius: r).fill(Color.concrete).frame(width: Size.row, height: Size.row)
                            .overlay(Text(verbatim: name).typeStyle(.readoutS).foregroundStyle(Color.dust))
                    }
                }
                .padding(Space.margin)
                SectionLabel(verbatim: "BUTTONS")
                VStack(spacing: Space.s12) {
                    PrimaryButton("Start meet") {}
                    PrimaryButton("Start meet", isLoading: true) {}
                    SecondaryButton("Continue with email") {}
                    QuietButton("Skip for now") {}
                    DestructiveButton("Delete car", confirmTitle: "Delete car", consequence: "Photos and timeline go too.") {}
                    HStack { IconButton(Symbol.add, label: "Add") {}; IconButton(Symbol.recenter, label: "Recenter", style: .overMap) {} }
                }
                .padding(.horizontal, Space.margin)
                SectionLabel(verbatim: "INPUTS")
                VStack(alignment: .leading, spacing: Space.s12) {
                    Field("Handle", text: .constant("maya_s197"), limit: 20)
                    Field("Handle", text: .constant("taken"), error: Text(verbatim: "Taken"))
                    HStack { Chip("Street", isSelected: true) {}; Chip("Built", isSelected: false) {} }
                    SegmentedSwitch(selection: .constant(0), options: [(0, "Following"), (1, "For you"), (2, "Showdown")])
                }
                .padding(.horizontal, Space.margin)
                SectionLabel(verbatim: "MEDIA AND READOUTS")
                HStack(spacing: Space.s12) {
                    ForEach(Avatar.Diameter.allCases, id: \.self) { Avatar(name: "Maya Okafor", size: $0) }
                }
                .padding(.horizontal, Space.margin)
                HStack(spacing: Space.s16) {
                    Readout("486", unit: "hp", label: "EST. HP", range: .init(low: 470, high: 500, bounds: 0...800))
                    Readout("12.1", unit: "s", label: "¼ MILE", range: .init(low: 11.8, high: 12.6, bounds: 8...18))
                }
                .padding(Space.margin)
                CarBadge("2019 Mustang GT", icon: "pony", paint: Color(rgb: 0x2B4C7E)).padding(.horizontal, Space.margin)
                SectionLabel(verbatim: "MARKERS ON A DARK MAP")
                MapIconGallery()
                SectionLabel(verbatim: "FEEDBACK")
                Banner(.offline)
                Banner(.reconnecting)
                SkeletonRow()
                EmptyState("No friends on the map yet.", actionTitle: "Invite a friend") {}
                ErrorState(Text(verbatim: "Couldn't load the feed.")) {}
            }
            .padding(.bottom, Space.s48)
        }
        .background(Color.asphalt.ignoresSafeArea())
        .navigationTitle("Design gallery")
    }
}

private extension Array {
    /// Splits into rows of `n`, for the icon gallery's fixed grid.
    func chunks(of n: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}

enum MapGlyphs {
    /// The 16 silhouettes free from the start — keep in sync with `MapGlyph.freeVehicles` in
    /// Core (DesignSystem cannot import Core).
    static let free = ["coupe", "sedan", "hatch", "wagon", "roadster", "muscle", "pony", "supercar",
                       "kei", "pickup", "suv", "van", "classic", "hot_rod", "sport_bike", "cruiser_bike"]
}

/// The "markers on a dark map" block: all 16 free silhouettes at the three marker sizes
/// (ICN-1 is judged from this), the anatomy row, and the report and meet marks. Shown inside
/// `Gallery` and on its own at `waypoints://debug/gallery-icons`.
public struct MapIconGallery: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([Size.Marker.stranger, Size.Marker.friend, Size.Marker.you], id: \.self) { size in
                // Fixed rows, not LazyVGrid: a grid in a debug sheet sizes past the proposed
                // width and centers the overflow off-screen.
                ForEach(MapGlyphs.free.chunks(of: 5), id: \.self) { row in
                    HStack(spacing: Space.s8) {
                        ForEach(row, id: \.self) { cell($0, size: size) }
                    }
                    .padding(.bottom, Space.s8)
                }
                .padding(.horizontal, Space.margin).padding(.vertical, Space.s8)
                .background(Color(rgb: 0x1B1D21))
            }
            HStack(spacing: Space.s16) {
                VehicleMarker(icon: "pony", paint: Color(rgb: 0x2B4C7E), role: .you, heading: 40)
                VehicleMarker(icon: "suv", paint: Color(rgb: 0xB11226), role: .friend(name: "Devon"), moving: true)
                VehicleMarker(icon: "hatch", paint: Color(rgb: 0xE5E5E5), role: .approximate)
                VehicleMarker(icon: "coupe", paint: .dust, role: .stranger)
                ClusterMarker(count: 12)
            }
            .padding(Space.margin)
            HStack(spacing: Space.s8) {
                ForEach(["speed_bump", "steep_entrance", "pothole", "rough_road", "police", "hazard", "closure", "fuel_e85"], id: \.self) {
                    ReportBadge(kind: $0)
                }
            }
            .padding(.horizontal, Space.margin)
            HStack(spacing: Space.s12) {
                ForEach(["meet", "cruise", "hangout", "track_day", "show"], id: \.self) { MeetPin(kind: $0, time: "8:00") }
            }
            .padding(Space.margin)
        }
    }

    private func cell(_ name: String, size: CGFloat) -> some View {
        VStack(spacing: Space.s2) {
            SilhouetteIcon(name, paint: Color(rgb: 0xB11226)).frame(width: size * 0.82, height: size * 0.82)
            Text(verbatim: name).typeStyle(.readoutS).foregroundStyle(Color.dust)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(minWidth: size, maxWidth: .infinity, minHeight: size)
    }
}

/// WCAG contrast for the text-on-surface pairs the app uses.
enum Contrast {
    struct Pair { let label: String; let ratio: Double; let minimum: Double }

    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ c: UInt32) -> Double {
            let v = Double(c) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((rgb >> 16) & 0xFF) + 0.7152 * channel((rgb >> 8) & 0xFF) + 0.0722 * channel(rgb & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static var pairs: [Pair] {
        let surfaces = [Palette.asphalt, Palette.tarmac, Palette.concrete]
        let texts: [(ColorToken, Double)] = [(Palette.chalk, 4.5), (Palette.dust, 4.5), (Palette.gravel, 3), (Palette.sodium, 3),
                                             (Palette.brake, 3), (Palette.go, 3)]
        var out = surfaces.flatMap { s in texts.map { t, min in Pair(label: "\(t.name) on \(s.name)", ratio: ratio(t.rgb, s.rgb), minimum: min) } }
        out.append(Pair(label: "asphalt on sodium", ratio: ratio(Palette.asphalt.rgb, Palette.sodium.rgb), minimum: 4.5))
        out.append(Pair(label: "asphalt on chalk", ratio: ratio(Palette.asphalt.rgb, Palette.chalk.rgb), minimum: 4.5))
        return out
    }
}
