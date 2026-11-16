import Core
import CoreLocation
import Foundation

/// Counters for a debug screen: samples admitted per sampler mode in the last minute.
public struct LocationDiagnostics: Sendable, Hashable {
    public var sharing: Bool
    public var authorization: LocationAuthorization
    public var mode: AdaptiveSampler.Mode?
    public var sentLastMinute: [AdaptiveSampler.Mode: Int]
    public var updatesRunning: Bool
}

/// Wraps `CLLocationUpdate.liveUpdates(.automotiveNavigation)` and applies the send-rate policy of
/// plan section 3.3. Updates run only while sharing is on and location is authorized.
public actor LiveLocationService: LocationService {
    private static let sharingKey = "app.waypoints.location.sharing"
    static let parkedLimit: Duration = .seconds(300)

    private let zoneStore: HomeZoneStore
    private let defaults: UserDefaults

    private var authorizationValue: LocationAuthorization = .notDetermined
    private var sharing: Bool
    private var zones: [HomeZone]
    private var navigationActive = false
    private var convoyActive = false
    private var stationary = false

    private var sampleBroadcast = Broadcast<LocationSample>(buffering: .bufferingNewest(1))
    private var authBroadcast = Broadcast<LocationAuthorization>()
    private var zoneBroadcast = Broadcast<[HomeZone]>()

    private var monitorTask: Task<AuthorizationMonitor, Never>?
    private var updatesTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var parkedTask: Task<Void, Never>?
    private var sampler = AdaptiveSampler()
    private var sent: [(Date, AdaptiveSampler.Mode)] = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.zoneStore = HomeZoneStore()
        self.sharing = defaults.object(forKey: Self.sharingKey) as? Bool ?? true
        self.zones = zoneStore.load()
    }

    // MARK: LocationService

    public func samples() async -> AsyncStream<LocationSample> {
        _ = await monitor()
        return sampleBroadcast.subscribe()
    }

    public func authorization() async -> AsyncStream<LocationAuthorization> {
        _ = await monitor()
        return authBroadcast.subscribe(initial: authorizationValue)
    }

    public func requestWhenInUse() async {
        let monitor = await monitor()
        await monitor.requestWhenInUse()
    }

    public func requestAlways() async {
        let monitor = await monitor()
        await monitor.requestAlways()
    }

    public func setSharing(_ on: Bool) async {
        _ = await monitor()
        sharing = on
        defaults.set(on, forKey: Self.sharingKey)
        reconcile()
    }

    public func setActive(_ activity: LocationActivity, _ active: Bool) async {
        switch activity {
        case .navigation: navigationActive = active
        case .convoy: convoyActive = active
        }
        reconcile()
    }

    public func homeZones() async -> AsyncStream<[HomeZone]> { zoneBroadcast.subscribe(initial: zones) }

    public func setHomeZones(_ zones: [HomeZone]) async throws {
        guard zones.count <= HomeZone.maximumCount else { throw WaypointsError.invalid("home_zones") }
        try zoneStore.save(zones)
        self.zones = zones
        zoneBroadcast.send(zones)
    }

    public func diagnostics() -> LocationDiagnostics {
        pruneSent(now: .now)
        let counts = Dictionary(grouping: sent, by: \.1).mapValues(\.count)
        return LocationDiagnostics(sharing: sharing, authorization: authorizationValue, mode: sampler.mode,
                                   sentLastMinute: counts, updatesRunning: updatesTask != nil)
    }

    // MARK: Authorization

    /// Creates the main-actor authorization monitor once; later callers await the same instance.
    private func monitor() async -> AuthorizationMonitor {
        if let monitorTask { return await monitorTask.value }
        let task = Task { @MainActor in
            AuthorizationMonitor { [weak self] status in
                guard let self else { return }
                Task { await self.authorizationChanged(status) }
            }
        }
        monitorTask = task
        let monitor = await task.value
        authorizationChanged(await monitor.current)
        return monitor
    }

    private func authorizationChanged(_ value: LocationAuthorization) {
        guard value != authorizationValue else { reconcile(); return }
        authorizationValue = value
        authBroadcast.send(value)
        reconcile()
    }

    // MARK: Updates

    /// What holds location alive in the background (PRV-12): Always authorization — the
    /// "Keep sharing when the app is closed" setting — or an active navigation or convoy.
    private var sessionWanted: Bool {
        authorizationValue == .always || navigationActive || convoyActive
    }

    /// Starts or stops the update loop so it runs exactly when sharing is on and authorized.
    private func reconcile() {
        let shouldRun = sharing && authorizationValue.allowsUse
        if shouldRun, updatesTask == nil {
            sampler.reset()
            updatesTask = Task { await self.runUpdates() }
        } else if !shouldRun, let task = updatesTask {
            task.cancel()
            updatesTask = nil
            parkedTask?.cancel()
            parkedTask = nil
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
        if shouldRun { applySession() }
    }

    /// Keeps the held background session in step with `sessionWanted`. Once parked has
    /// stopped it under keep-sharing alone, only movement or an activity restarts it.
    private func applySession() {
        if sessionWanted {
            if backgroundSession == nil, navigationActive || convoyActive || !stationary {
                backgroundSession = CLBackgroundActivitySession()
            }
        } else {
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
        parked(stationary)
    }

    /// PRV-12: five minutes parked ends background sharing; the next movement seen while the
    /// app is open starts it again. An active navigation or convoy holds the session parked.
    private func parked(_ stationary: Bool) {
        self.stationary = stationary
        if !stationary {
            parkedTask?.cancel()
            parkedTask = nil
            if sessionWanted, backgroundSession == nil { backgroundSession = CLBackgroundActivitySession() }
        } else if navigationActive || convoyActive {
            parkedTask?.cancel()
            parkedTask = nil
        } else if parkedTask == nil, backgroundSession != nil {
            parkedTask = Task {
                try? await Task.sleep(for: Self.parkedLimit)
                if Task.isCancelled { return }
                self.backgroundSession?.invalidate()
                self.backgroundSession = nil
            }
        }
    }

    private func runUpdates() async {
        do {
            for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                if Task.isCancelled { break }
                parked(update.stationary)
                guard let location = update.location else { continue }
                handle(sample(from: location, stationary: update.stationary))
            }
        } catch {
            // The stream ends on cancellation or a Core Location failure; `reconcile` restarts it
            // on the next sharing or authorization change.
        }
        if !Task.isCancelled {
            updatesTask = nil
            parkedTask?.cancel()
            parkedTask = nil
            backgroundSession?.invalidate()
            backgroundSession = nil
        }
    }

    private func sample(from location: CLLocation, stationary: Bool) -> LocationSample {
        LocationSample(
            coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
            heading: location.course >= 0 ? location.course : nil,
            speed: max(0, location.speed),
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            isStationary: stationary
        )
    }

    private func handle(_ sample: LocationSample) {
        guard let mode = sampler.admit(sample) else { return }
        sent.append((sample.timestamp, mode))
        pruneSent(now: sample.timestamp)
        sampleBroadcast.send(sample)
    }

    private func pruneSent(now: Date) {
        sent.removeAll { now.timeIntervalSince($0.0) > 60 }
    }
}
