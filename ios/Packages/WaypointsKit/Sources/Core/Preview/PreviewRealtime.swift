import Foundation

/// Simulated gateway feed: the seed friends driving loops around Cherry Hill, two approximate
/// teammates, and two nearby strangers. One batch per second per consumer.
public actor PreviewRealtimeService: RealtimeService {
    struct Driver: Sendable {
        let uid: RealtimeUID
        let center: Coordinate
        let radius: Double              // degrees
        let period: Double              // seconds per loop
        let tier: LocationTier
        let info: EntityInfo
    }

    private let drivers: [Driver]
    private var viewport: MapRegion = PreviewSeed.region
    private var stateBroadcast = Broadcast<ConnectionState>()
    private var convoy: ConvoyID?

    public init() {
        func info(_ relation: Relation, _ user: UserID) -> EntityInfo {
            let profile = PreviewSeed.profiles.first { $0.userID == user }!
            let car = PreviewSeed.cars.first { $0.id == profile.primaryCarID }
            let rgb = car?.colorHex.flatMap { UInt32($0.dropFirst(), radix: 16) } ?? 0xA8A6A0
            let nearby = relation == .nearby
            return EntityInfo(relation: relation, markerIcon: profile.markerIcon, paintRGB: rgb,
                              displayName: nearby ? "" : profile.displayName, carLabel: nearby ? "" : car?.shortLabel ?? "")
        }
        let s = PreviewSeed.self
        drivers = [
            Driver(uid: 2, center: s.at(39.9300, -75.0200), radius: 0.012, period: 240, tier: .precise, info: info(.friend, s.devon)),
            Driver(uid: 3, center: s.at(39.9000, -75.0350), radius: 0.008, period: 180, tier: .precise, info: info(.friend, s.jae)),
            Driver(uid: 4, center: s.at(39.9100, -74.9300), radius: 0.020, period: 400, tier: .precise, info: info(.friend, s.rosa)),
            Driver(uid: 6, center: s.at(39.8700, -75.0000), radius: 0.010, period: 300, tier: .approximate, info: info(.friend, s.nina)),
            Driver(uid: 8, center: s.at(39.9700, -74.9500), radius: 0.015, period: 320, tier: .approximate, info: info(.teammate, s.lena)),
            Driver(uid: 101, center: s.at(39.9450, -75.0500), radius: 0.006, period: 200, tier: .approximate,
                   info: EntityInfo(relation: .nearby, markerIcon: "sedan", paintRGB: 0, displayName: "", carLabel: "")),
            Driver(uid: 102, center: s.at(39.9250, -75.0700), radius: 0.009, period: 260, tier: .approximate,
                   info: EntityInfo(relation: .nearby, markerIcon: "suv", paintRGB: 0, displayName: "", carLabel: "")),
        ]
    }

    func update(_ driver: Driver, at t: Double, includeInfo: Bool) -> EntityUpdate {
        let angle = (t / driver.period) * 2 * .pi
        let approximate = driver.tier == .approximate
        // Approximate drivers snap to a coarse grid (stands in for the gateway's H3 r8 snapping).
        let step = approximate ? 0.005 : 0
        var lat = driver.center.latitude + driver.radius * sin(angle)
        var lng = driver.center.longitude + driver.radius * 1.3 * cos(angle)
        if approximate { lat = (lat / step).rounded() * step; lng = (lng / step).rounded() * step }
        let heading = (450 - angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        return EntityUpdate(uid: driver.uid, coordinate: Coordinate(latitude: lat, longitude: lng),
                            heading: approximate ? nil : heading, tier: driver.tier, age: 0.4,
                            info: includeInfo ? driver.info : nil)
    }

    func snapshot(first: Bool) -> [EntityUpdate] {
        let t = Date.now.timeIntervalSinceReferenceDate
        return drivers.map { update($0, at: t, includeInfo: first) }.filter { viewport.contains($0.coordinate) }
    }

    public func events() async -> AsyncStream<ServerEvent> {
        let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let task = Task { [weak self] in
            var first = true
            while !Task.isCancelled, let self {
                continuation.yield(.entities(await self.snapshot(first: first)))
                first = false
                try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func connectionState() async -> AsyncStream<ConnectionState> { stateBroadcast.subscribe(initial: .live) }
    public func setViewport(_ region: MapRegion) async { viewport = region }
    public func send(_ sample: LocationSample) async {}
    public func joinConvoy(_ id: ConvoyID) async { convoy = id }
    public func leaveConvoy() async { convoy = nil }
}

/// Simulated location: parked at the Cherry Hill Mall lot, permission granted.
public actor PreviewLocationService: LocationService {
    private var authorization: LocationAuthorization
    private var authBroadcast = Broadcast<LocationAuthorization>()
    private var sharing = true
    private var zones: [HomeZone] = []
    private var zoneBroadcast = Broadcast<[HomeZone]>()

    public init(authorization: LocationAuthorization = .whenInUse) { self.authorization = authorization }

    public func samples() async -> AsyncStream<LocationSample> {
        let (stream, continuation) = AsyncStream<LocationSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            while !Task.isCancelled {
                continuation.yield(LocationSample(coordinate: PreviewSeed.at(39.9405, -75.0094), heading: 90, speed: 0,
                                                  horizontalAccuracy: 8, isStationary: true))
                try? await Task.sleep(for: .seconds(5))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
    public func authorization() async -> AsyncStream<LocationAuthorization> {
        authBroadcast.subscribe(initial: authorization)
    }
    public func requestWhenInUse() async { set(.whenInUse) }
    public func requestAlways() async { set(.always) }
    public func setSharing(_ on: Bool) async { sharing = on }
    public func homeZones() async -> AsyncStream<[HomeZone]> { zoneBroadcast.subscribe(initial: zones) }
    public func setHomeZones(_ zones: [HomeZone]) async throws {
        guard zones.count <= HomeZone.maximumCount else { throw WaypointsError.invalid("home_zones") }
        self.zones = zones
        zoneBroadcast.send(zones)
    }
    private func set(_ value: LocationAuthorization) {
        guard value != authorization, authorization != .always else { return }
        authorization = value
        authBroadcast.send(value)
    }
}

/// Catalog backed by the handful of variants in `PreviewSeed`.
public struct PreviewVehicleCatalogService: VehicleCatalogService {
    public init() {}
    private var variants: [CatalogVariant] { PreviewSeed.catalogVariants }

    public func search(_ query: String, limit: Int) async throws -> [CatalogVariant] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return Array(variants.filter { variant in
            let haystack = variant.label.lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }.prefix(limit))
    }
    public func popularMakes() async throws -> [CatalogMake] {
        let order = ["Ford", "Honda", "Toyota", "Chevrolet", "Subaru", "BMW", "Nissan", "Mazda", "Volkswagen", "Dodge", "Ram", "Hyundai"]
        return order.compactMap { name in PreviewSeed.catalogMakes.first { $0.name == name } }
    }
    public func makes() async throws -> [CatalogMake] { PreviewSeed.catalogMakes }
    public func models(of make: Int64) async throws -> [CatalogModel] {
        PreviewSeed.catalogModels.filter { $0.makeID == make }.sorted { $0.yearTo > $1.yearTo }
    }
    public func years(of model: Int64) async throws -> [Int] {
        guard let m = PreviewSeed.catalogModels.first(where: { $0.id == model }) else { return [] }
        return Array((m.yearFrom...m.yearTo).reversed())
    }
    public func variants(of model: Int64, year: Int) async throws -> [CatalogVariant] {
        variants.filter { $0.modelID == model && $0.year == year }
    }
    public func variant(_ id: Int64) async throws -> CatalogVariant? { variants.first { $0.id == id } }
    public func decodeVIN(_ vin: String) async throws -> VINDecode {
        guard vin.count == 17 else { throw WaypointsError.invalid("vin") }
        let v = variants[0]
        return VINDecode(year: v.year, make: v.make, model: v.model, trim: v.trim, variantID: v.id)
    }
}
