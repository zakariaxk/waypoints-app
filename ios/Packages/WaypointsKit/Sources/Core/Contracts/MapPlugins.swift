import SwiftUI

// Map plug-ins (consumed by MapFeature, supplied by other features through AppShell). Plan 4.3.

public protocol MapLayerProvider: Sendable {
    var id: String { get }
    func items(in region: MapRegion) -> AsyncStream<[MapItem]>      // re-called when the camera settles
    @MainActor func detail(for item: MapItem) -> AnyView?           // shown in the map sheet on selection
}

public struct MapItem: Identifiable, Sendable {
    public let id: String
    public var coordinate: Coordinate
    public var glyph: MapGlyph            // DesignSystem-rendered by name
    public var tint: MapTint
    public var title: String?
    public var priority: Int              // higher wins when crowded

    public init(id: String, coordinate: Coordinate, glyph: MapGlyph, tint: MapTint, title: String? = nil, priority: Int = 0) {
        self.id = id; self.coordinate = coordinate; self.glyph = glyph; self.tint = tint
        self.title = title; self.priority = priority
    }
}

public protocol MapSheetSection: Sendable {                         // rows in the map's bottom sheet
    var id: String { get }; var order: Int { get }
    @MainActor func view(region: MapRegion) -> AnyView
}

public protocol MapAction: Sendable {                                // entries in the map's add menu
    var id: String { get }; var title: String { get }; var symbol: String { get }; var order: Int { get }
    @MainActor func perform(at coordinate: Coordinate, router: any Router)
}

public protocol FeedMode: Sendable {                                 // extra modes in the Feed tab's top switch (Showdown)
    var id: String { get }; var title: String { get }; var order: Int { get }
    @MainActor func view() -> AnyView
}

/// Name of a drawing in `DesignSystem/MapIcons` (section 9.8). Core has no UI, so a glyph is a name.
public struct MapGlyph: Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let name: String
    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { self.name = value }

    /// The 16 silhouettes free from the start.
    public static let freeVehicles: [MapGlyph] = [
        "coupe", "sedan", "hatch", "wagon", "roadster", "muscle", "pony", "supercar",
        "kei", "pickup", "suv", "van", "classic", "hot_rod", "sport_bike", "cruiser_bike",
    ]
    public static func report(_ kind: ReportKind) -> MapGlyph { MapGlyph("report.\(kind.rawValue)") }
    public static func meet(_ kind: MeetKind) -> MapGlyph { MapGlyph("meet.\(kind.rawValue)") }
}

/// Semantic tint; DesignSystem maps each case to a token (section 9.2).
public enum MapTint: Hashable, Sendable {
    case paint(rgb: UInt32)       // a user's car color, inside silhouettes only
    case sodium, brake, go, xenon, dust, chalk
}
