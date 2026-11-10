import Foundation

public struct Coordinate: Hashable, Sendable, Codable {
    public var latitude, longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in meters (haversine).
    public func distance(to other: Coordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLng = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(latitude * .pi / 180) * cos(other.latitude * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// A latitude/longitude bounding box, the shape of `SetViewport` and the `*_in_bbox` RPCs.
public struct MapRegion: Hashable, Sendable, Codable {
    public var minLatitude: Double
    public var minLongitude: Double
    public var maxLatitude: Double
    public var maxLongitude: Double

    public init(minLatitude: Double, minLongitude: Double, maxLatitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.minLongitude = minLongitude
        self.maxLatitude = maxLatitude
        self.maxLongitude = maxLongitude
    }

    public init(center: Coordinate, latitudeDelta: Double, longitudeDelta: Double) {
        self.init(
            minLatitude: center.latitude - latitudeDelta / 2,
            minLongitude: center.longitude - longitudeDelta / 2,
            maxLatitude: center.latitude + latitudeDelta / 2,
            maxLongitude: center.longitude + longitudeDelta / 2
        )
    }

    public var center: Coordinate {
        Coordinate(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
    }
    public var latitudeDelta: Double { maxLatitude - minLatitude }
    public var longitudeDelta: Double { maxLongitude - minLongitude }

    public func contains(_ c: Coordinate) -> Bool {
        (minLatitude...maxLatitude).contains(c.latitude) && (minLongitude...maxLongitude).contains(c.longitude)
    }
}
