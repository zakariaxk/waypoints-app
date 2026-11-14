import Core
import Foundation
import Network
import WireProtocol

/// Numbers for a debug screen (plan W1-3 acceptance).
public struct RealtimeDiagnostics: Sendable {
    public var state: ConnectionState
    /// Our own uid from the last `Welcome`.
    public var uid: RealtimeUID?
    /// Round trip of the last `Ping`/`Pong`.
    public var roundTrip: TimeInterval?
    /// Entities currently in view (updates minus `gone`).
    public var visibleEntities: Int
    public var entityUpdatesReceived: Int
    public var framesSent: Int
    public var locationUpdatesSent: Int
    /// Connection attempts since launch.
    public var connectionAttempts: Int
    /// Live tasks owned by the connection: the reconnect loop plus its receive, send, and heartbeat
    /// children. Stays at 4 while live and 1 while backing off; anything else is a leak.
    public var activeTasks: Int
}

/// Owns the gateway WebSocket (plan sections 3.2 and 6).
///
/// One connection is one throwing task group with three children: receive, send, heartbeat.
/// Ending any of them cancels the socket and the other two. A reconnect loop wraps the group with
/// full-jitter backoff (0.5 s doubling to 30 s, reset after 30 s live); a network path change
/// cuts the wait short. Auth session changes restart the loop for a new user or send
/// `RefreshToken` for the same one.
public actor LiveRealtimeService: RealtimeService {
    private enum ConnectionEnd: Error { case fatal, timeout }

    static let heartbeatInterval: Duration = .seconds(25)
    static let silenceLimit: TimeInterval = 60
    static let stableAfter: TimeInterval = 30
    static let backoffBase: TimeInterval = 0.5
    static let backoffCap: TimeInterval = 30

    private let config: AppConfig
    private let auth: any AuthService
    private let location: (any LocationService)?
    private let session = URLSession(configuration: .ephemeral)
    private let socketURL: URL

    private var eventBroadcast = Broadcast<ServerEvent>(buffering: .bufferingNewest(256))
    private var stateBroadcast = Broadcast<ConnectionState>()
    private var pathBroadcast = Broadcast<Bool>()
    private var state: ConnectionState = .offline
    private var pathSatisfied = true

    // Desired state, replayed after every `Hello`.
    private var viewport: MapRegion?
    private var convoy: ConvoyID?
    /// What `activeConvoy()` reports: the joined convoy's latest state.
    private var convoyState: ConvoyState?
    private var convoyBroadcast = Broadcast<ConvoyState?>()
    private var zones: [HomeZone] = []

    private var started = false
    private var supervisorTask: Task<Void, Never>?
    private var zonesTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?

    // Per-connection state.
    private var outbox: AsyncStream<Waypoints_V1_ClientFrame>.Continuation?
    private var signedInUser: UserID?
    private var lastToken: String?
    private var liveSince: Date?
    private var lastReceived = Date.distantPast
    private var seq: UInt32 = 0
    private var visible: Set<RealtimeUID> = []
    /// Entities shown before a reconnect; whatever the first new `Batch` omits is reported gone.
    private var staleFromPrevious: Set<RealtimeUID>?

    // Diagnostics.
    private var uid: RealtimeUID?
    private var roundTrip: TimeInterval?
    private var entityUpdatesReceived = 0
    private var framesSent = 0
    private var locationUpdatesSent = 0
    private var connectionAttempts = 0
    private var activeChildren = 0

    public init(config: AppConfig, auth: any AuthService, location: (any LocationService)? = nil) {
        self.config = config
        self.auth = auth
        self.location = location
        var components = URLComponents(url: config.gatewayURL, resolvingAgainstBaseURL: false)
        components?.scheme = switch config.gatewayURL.scheme {
        case "https", "wss": "wss"
        default: "ws"
        }
        components?.path = RealtimeProtocol.path
        socketURL = components?.url ?? config.gatewayURL.appending(path: RealtimeProtocol.path)
    }

    // MARK: RealtimeService

    public func events() -> AsyncStream<ServerEvent> {
        start()
        return eventBroadcast.subscribe()
    }

    public func connectionState() -> AsyncStream<ConnectionState> {
        start()
        return stateBroadcast.subscribe(initial: state)
    }

    public func setViewport(_ region: MapRegion) {
        start()
        viewport = region
        outbox?.yield(WireMapping.viewport(region))
    }

    /// Dropped unless live: location is conflatable, and the next fix supersedes this one.
    public func send(_ sample: LocationSample) {
        start()
        guard case .live = state, let outbox else { return }
        seq &+= 1
        locationUpdatesSent += 1
        outbox.yield(WireMapping.location(sample, seq: seq))
    }

    public func joinConvoy(_ id: ConvoyID) {
        start()
        convoy = id
        if convoyState?.id != id { setConvoy(ConvoyState(id: id, leaderUID: 0, memberUIDs: [])) }
        outbox?.yield(WireMapping.join(id))
    }

    public func leaveConvoy() {
        start()
        guard convoy != nil else { return }
        convoy = nil
        setConvoy(nil)
        outbox?.yield(WireMapping.leave())
    }

    public func activeConvoy() -> AsyncStream<ConvoyState?> {
        start()
        return convoyBroadcast.subscribe(initial: .some(convoyState))
    }

    public func currentConvoy() -> ConvoyState? { convoyState }

    private func setConvoy(_ new: ConvoyState?) {
        guard new != convoyState else { return }
        convoyState = new
        convoyBroadcast.send(new)
    }

    public func diagnostics() -> RealtimeDiagnostics {
        RealtimeDiagnostics(state: state, uid: uid, roundTrip: roundTrip, visibleEntities: visible.count,
                            entityUpdatesReceived: entityUpdatesReceived, framesSent: framesSent,
                            locationUpdatesSent: locationUpdatesSent, connectionAttempts: connectionAttempts,
                            activeTasks: activeChildren + (connectionTask == nil ? 0 : 1))
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            Task { await self.pathChanged(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "app.waypoints.realtime.path"))
        pathMonitor = monitor

        supervisorTask = Task { await self.supervise() }
        if let location {
            zonesTask = Task {
                for await zones in await location.homeZones() { self.zonesChanged(zones) }
            }
        }
    }

    private func supervise() async {
        for await session in await auth.sessions() {
            guard let session else {
                signedInUser = nil
                lastToken = nil
                await stopConnection()
                setState(.offline)
                continue
            }
            if session.userID == signedInUser {
                if session.accessToken != lastToken {
                    lastToken = session.accessToken
                    outbox?.yield(WireMapping.refresh(token: session.accessToken))
                }
                continue
            }
            await stopConnection()
            signedInUser = session.userID
            lastToken = session.accessToken
            connectionTask = Task { await self.reconnectLoop() }
        }
    }

    /// Cancels the reconnect loop and waits for it, so no task outlives the old session.
    private func stopConnection() async {
        guard let task = connectionTask else { return }
        connectionTask = nil
        task.cancel()
        await task.value
    }

    private func reconnectLoop() async {
        var attempt = 0
        while !Task.isCancelled {
            setState(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
            connectionAttempts += 1
            let (fatal, stable) = await connectOnce()
            if Task.isCancelled { break }
            if fatal { setState(.offline); return }
            attempt = stable ? 1 : attempt + 1
            setState(pathSatisfied ? .reconnecting(attempt: attempt) : .offline)
            await backoff(attempt: attempt)
        }
    }

    /// Full jitter: a uniform wait in `0...min(30, 0.5 * 2^(attempt-1))` seconds, cut short when
    /// the network path becomes satisfied.
    private func backoff(attempt: Int) async {
        let cap = min(Self.backoffCap, Self.backoffBase * pow(2, Double(attempt - 1)))
        let delay = Double.random(in: 0...cap)
        let wake = pathBroadcast.subscribe()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: .seconds(delay)) }
            group.addTask { for await satisfied in wake where satisfied { return } }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: One connection

    /// Runs one socket until it ends. Returns whether the end is fatal (do not retry) and whether
    /// the connection had been live long enough to reset the backoff.
    private func connectOnce() async -> (fatal: Bool, stable: Bool) {
        let token: String
        do { token = try await auth.accessToken() } catch { return (false, false) }
        if Task.isCancelled { return (false, false) }
        lastToken = token

        var request = URLRequest(url: socketURL)
        request.timeoutInterval = 15
        let ws = session.webSocketTask(with: request)

        // Handshake order from plan section 6: Hello, SetHomeZones, SetViewport, JoinConvoy.
        let (frames, continuation) = AsyncStream<Waypoints_V1_ClientFrame>.makeStream()
        continuation.yield(WireMapping.hello(token: token, appVersion: config.appVersion))
        continuation.yield(WireMapping.homeZones(zones))
        if let viewport { continuation.yield(WireMapping.viewport(viewport)) }
        if let convoy { continuation.yield(WireMapping.join(convoy)) }
        outbox = continuation
        liveSince = nil
        lastReceived = .now
        ws.resume()

        var fatal = false
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.receiveLoop(ws) }
                    group.addTask { try await self.sendLoop(ws, frames) }
                    group.addTask { try await self.heartbeat() }
                    // Whichever child ends first takes the socket down; cancelling the socket
                    // unblocks `receive()`, which does not observe task cancellation on its own.
                    defer {
                        ws.cancel(with: .goingAway, reason: nil)
                        group.cancelAll()
                    }
                    _ = try await group.next()
                }
            } onCancel: {
                ws.cancel(with: .goingAway, reason: nil)
            }
        } catch ConnectionEnd.fatal {
            fatal = true
        } catch {
            // Closed, timed out, or cancelled: the reconnect loop decides.
        }

        continuation.finish()
        outbox = nil
        let stable = liveSince.map { Date.now.timeIntervalSince($0) >= Self.stableAfter } ?? false
        liveSince = nil
        if !visible.isEmpty { staleFromPrevious = visible.union(staleFromPrevious ?? []) }
        visible.removeAll()
        return (fatal, stable)
    }

    private func receiveLoop(_ ws: URLSessionWebSocketTask) async throws {
        activeChildren += 1
        defer { activeChildren -= 1 }
        while true {
            let message = try await ws.receive()
            lastReceived = .now
            guard case .data(let data) = message,
                  let frame = try? Waypoints_V1_ServerFrame(serializedBytes: data) else { continue }
            try handle(frame)
        }
    }

    private func sendLoop(_ ws: URLSessionWebSocketTask, _ frames: AsyncStream<Waypoints_V1_ClientFrame>) async throws {
        activeChildren += 1
        defer { activeChildren -= 1 }
        for await frame in frames {
            let data: Data = try frame.serializedBytes()
            try await ws.send(.data(data))
            framesSent += 1
        }
    }

    /// Pings every 25 s (the stationary heartbeat of plan 3.3) and gives up on a silent socket.
    private func heartbeat() async throws {
        activeChildren += 1
        defer { activeChildren -= 1 }
        while true {
            try await Task.sleep(for: Self.heartbeatInterval)
            if Date.now.timeIntervalSince(lastReceived) > Self.silenceLimit { throw ConnectionEnd.timeout }
            outbox?.yield(WireMapping.ping())
        }
    }

    private func handle(_ frame: Waypoints_V1_ServerFrame) throws {
        switch frame.body {
        case .welcome(let welcome):
            uid = welcome.uid
            liveSince = .now
            setState(.live)
            outbox?.yield(WireMapping.ping())
        case .batch(let batch):
            handle(batch)
        case .pong(let pong):
            roundTrip = max(0, Date.now.timeIntervalSince(WireMapping.date(ms: pong.clientMs)))
        case .error(let error):
            // The server closes after errors it considers terminal; only a protocol mismatch is
            // not worth retrying. UNAUTHORIZED retries with a freshly refreshed token.
            if error.code == .protocolVersion { throw ConnectionEnd.fatal }
        case .convoy(let state):
            let model = WireMapping.convoy(state)
            if model.id == convoy {
                if model.ended { convoy = nil; setConvoy(nil) } else { setConvoy(model) }
            }
            eventBroadcast.send(.convoy(model))
        case .mapEvent(let event):
            if let event = WireMapping.mapEvent(event) { eventBroadcast.send(.mapEvent(event)) }
        case nil:
            break
        }
    }

    private func handle(_ batch: Waypoints_V1_Batch) {
        var gone = batch.gone
        if let stale = staleFromPrevious {
            staleFromPrevious = nil
            gone += stale.subtracting(batch.updates.map(\.uid))
        }
        if !batch.updates.isEmpty {
            entityUpdatesReceived += batch.updates.count
            visible.formUnion(batch.updates.map(\.uid))
            eventBroadcast.send(.entities(batch.updates.map(WireMapping.entity)))
        }
        if !gone.isEmpty {
            visible.subtract(gone)
            eventBroadcast.send(.gone(gone))
        }
        if !batch.aggregates.isEmpty {
            eventBroadcast.send(.aggregates(batch.aggregates.map(WireMapping.aggregate)))
        }
    }

    // MARK: State

    private func setState(_ new: ConnectionState) {
        state = new
        stateBroadcast.send(new)
    }

    private func pathChanged(_ satisfied: Bool) {
        guard satisfied != pathSatisfied else { return }
        pathSatisfied = satisfied
        pathBroadcast.send(satisfied)
        if !satisfied, case .reconnecting = state { setState(.offline) }
    }

    private func zonesChanged(_ zones: [HomeZone]) {
        self.zones = zones
        outbox?.yield(WireMapping.homeZones(zones))
    }
}
