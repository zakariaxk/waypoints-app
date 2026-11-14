import Core
import DesignSystem
import SwiftUI

/// The Map tab (plan 10.3: M1, M2, M7, M8, M10), the live entity store, and the slots other
/// features plug into (layers, sheet sections, add-menu actions).
public enum MapFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        let model = MapModel(env: env, registry: registry)
        registry.registerTab(.map, onReselect: { model.recenter() }) { AnyView(MapScreen(model: model)) }
        model.start()
    }
}

/// One live driver as the store knows it.
struct Entity: Identifiable, Hashable, Sendable {
    var id: RealtimeUID { uid }
    var uid: RealtimeUID
    var coordinate: Coordinate
    var heading: Double?
    var tier: LocationTier
    var info: EntityInfo?
    var fixAt: Date
    var previous: Coordinate?

    var staleness: TimeInterval { Date.now.timeIntervalSince(fixAt) }
    var moving: Bool { previous.map { $0.distance(to: coordinate) > 5 } ?? false }
}

/// Consumes server events, keeps the latest state per entity, and publishes snapshots to the
/// main actor at most 10 times per second (plan 3.2).
actor LiveEntityStore {
    private var entities: [RealtimeUID: Entity] = [:]
    private var infos: [RealtimeUID: EntityInfo] = [:]
    private var aggregates: [UInt64: Int] = [:]
    private var dirty = false

    func apply(_ event: ServerEvent) {
        switch event {
        case let .entities(updates):
            for u in updates {
                if let info = u.info { infos[u.uid] = info }
                let old = entities[u.uid]
                entities[u.uid] = Entity(uid: u.uid, coordinate: u.coordinate, heading: u.heading, tier: u.tier,
                                         info: infos[u.uid], fixAt: Date.now.addingTimeInterval(-u.age),
                                         previous: old?.coordinate)
            }
            dirty = true
        case let .gone(uids):
            for uid in uids { entities[uid] = nil }
            dirty = true
        case let .aggregates(cells):
            for c in cells { aggregates[c.h3] = c.count }
            dirty = true
        case .mapEvent, .convoy:
            break
        }
    }

    /// Drops markers stale for 30 minutes (plan 9.8) and returns a snapshot when something changed.
    func take() -> (entities: [Entity], aggregateCount: Int)? {
        let cutoff = Date.now.addingTimeInterval(-30 * 60)
        let before = entities.count
        entities = entities.filter { $0.value.fixAt > cutoff }
        guard dirty || entities.count != before else { return nil }
        dirty = false
        return (Array(entities.values), aggregates.values.reduce(0, +))
    }
}

enum Selection: Hashable {
    case entity(RealtimeUID)
    case item(provider: String, id: String)
}

enum FollowMode { case none, follow, heading }

@MainActor
@Observable
final class MapModel {
    let env: AppEnvironment
    @ObservationIgnored let registry: FeatureRegistry
    @ObservationIgnored private let store = LiveEntityStore()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var layerTasks: [String: Task<Void, Never>] = [:]

    var entities: [Entity] = []
    var aggregateCount = 0
    var friends: [Friend] = []
    var me: LocationSample?
    var profile: Profile?
    var primaryCar: Car?
    var privacy = PrivacySettings.defaults
    var authorization: LocationAuthorization = .notDetermined
    var connection: ConnectionState = .connecting
    var blocked: Set<UserID> = []
    var region = MapRegion(center: Coordinate(latitude: 39.95, longitude: -75.16), latitudeDelta: 0.2, longitudeDelta: 0.2)
    var items: [String: [MapItem]] = [:]
    var selection: Selection?
    var follow: FollowMode = .follow
    var recenterTick = 0
    var hasLiveBatch = false
    var showBanner = false

    var layers: [String: Bool] {
        didSet { UserDefaults.standard.set(layers, forKey: "map.layers") }
    }

    init(env: AppEnvironment, registry: FeatureRegistry) {
        self.env = env
        self.registry = registry
        layers = (UserDefaults.standard.dictionary(forKey: "map.layers") as? [String: Bool]) ?? [:]
    }

    func isOn(_ layer: String) -> Bool { layers[layer] ?? (layer != "traffic") }

    func start() {
        guard tasks.isEmpty else { return }
        let env = self.env
        let store = self.store
        tasks.append(Task { [weak self] in
            for await event in await env.realtime.events() {
                await store.apply(event)
                if case .mapEvent = event { self?.reloadLayers() }
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if let snap = await store.take() {
                    self?.entities = snap.entities
                    self?.aggregateCount = snap.aggregateCount
                    self?.hasLiveBatch = true
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await state in await env.realtime.connectionState() {
                self?.connection = state
                if case .live = state { self?.showBanner = false } else {
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        if let self, !(self.connectionIsLive) { self.showBanner = true }
                    }
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await sample in await env.location.samples() {
                self?.me = sample
                await env.realtime.send(sample)
            }
        })
        tasks.append(Task { [weak self] in
            for await a in await env.location.authorization() { self?.authorization = a }
        })
        tasks.append(Task { [weak self] in
            for await list in await env.friends.friendChanges() { self?.friends = list }
        })
        tasks.append(Task { [weak self] in
            for await set in await env.safety.blockedChanges() { self?.blocked = set }
        })
        tasks.append(Task { [weak self] in
            for await p in await env.profiles.myProfileChanges() {
                self?.profile = p
                if let id = p.primaryCarID { self?.primaryCar = try? await env.garage.car(id) }
            }
        })
        tasks.append(Task { [weak self] in
            self?.privacy = (try? await env.profiles.myPrivacySettings()) ?? .defaults
            if let p = try? await env.profiles.myProfile() {
                self?.profile = p
                if let id = p.primaryCarID { self?.primaryCar = try? await env.garage.car(id) }
            }
        })
    }

    var connectionIsLive: Bool { if case .live = connection { true } else { false } }

    var banner: BannerState? {
        guard showBanner else { return nil }
        if case .offline = connection { return .offline }
        return .reconnecting
    }

    func recenter() {
        follow = follow == .follow ? .heading : .follow
        recenterTick += 1
    }

    func cameraSettled(_ r: MapRegion) {
        region = r
        Task { await env.realtime.setViewport(r) }
        reloadLayers()
    }

    func reloadLayers() {
        for provider in registry.mapLayers {
            layerTasks[provider.id]?.cancel()
            let r = region
            layerTasks[provider.id] = Task { [weak self] in
                for await list in provider.items(in: r) {
                    self?.items[provider.id] = list
                }
            }
        }
    }

    /// Friend by wire uid.
    func friend(uid: RealtimeUID) -> Friend? { friends.first { $0.profile.uid == uid } }

    var visibleEntities: [Entity] {
        entities.filter { e in
            if let f = friend(uid: e.uid), blocked.contains(f.profile.userID) { return false }
            switch e.info?.relation {
            case .nearby: return isOn("nearby")
            default: return isOn("friends")
            }
        }
    }

    var friendsOut: [Friend] {
        let uids = Set(entities.map(\.uid))
        return friends.filter { uids.contains($0.profile.uid) && !blocked.contains($0.profile.userID) }
    }

    func setGhost(until: Date?) {
        var s = privacy
        s.ghostUntil = until
        privacy = s
        Task { try? await env.gateway.updatePrivacy(s) }
    }

    /// "2.1 mi north east", in the locale's road unit (SET-3).
    func distanceLine(to c: Coordinate) -> String {
        guard let me else { return "" }
        let dLat = c.latitude - me.coordinate.latitude
        let dLng = c.longitude - me.coordinate.longitude
        let angle = (atan2(dLng, dLat) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let dirs = [String(localized: "north"), String(localized: "north east"), String(localized: "east"),
                    String(localized: "south east"), String(localized: "south"), String(localized: "south west"),
                    String(localized: "west"), String(localized: "north west")]
        let dir = dirs[Int((angle + 22.5) / 45) % 8]
        return "\(distanceText(to: c)) \(dir)"
    }

    /// Straight-line distance from you, miles or kilometres by locale, one decimal.
    func distanceText(to c: Coordinate) -> String {
        guard let me else { return "" }
        let meters = Measurement(value: me.coordinate.distance(to: c), unit: UnitLength.meters)
        let unit: UnitLength = Locale.current.measurementSystem == .metric ? .kilometers : .miles
        return meters.converted(to: unit).formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                                                 numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    /// MAP-12: in a convoy (Core's `RealtimeService.currentConvoy()`), push its join code to this
    /// friend; otherwise open the start sheet.
    func inviteToConvoy(_ user: UserID) {
        let env = self.env
        Task {
            if let id = await env.realtime.currentConvoy()?.id {
                try? await env.gateway.inviteToConvoy(id, users: [user])
            } else {
                env.router.open(.joinConvoy(code: ""))
            }
        }
    }
}

extension MapTint {
    var color: Color {
        switch self {
        case let .paint(rgb): Color(rgb: rgb)
        case .sodium: .sodium
        case .brake: .brake
        case .go: .go
        case .xenon: .xenon
        case .dust: .dust
        case .chalk: .chalk
        }
    }
}

extension Car {
    var paint: Color { colorHex.flatMap { Color(paintHex: $0) } ?? .dust }
}
