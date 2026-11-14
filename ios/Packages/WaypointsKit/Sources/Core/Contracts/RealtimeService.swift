import Foundation

/// Implemented by `RealtimeClient` (plan section 4.3).
public protocol RealtimeService: Sendable {
    func events() async -> AsyncStream<ServerEvent>          // multi-consumer: each call gets its own stream
    func connectionState() async -> AsyncStream<ConnectionState>
    func setViewport(_ region: MapRegion) async
    func send(_ sample: LocationSample) async
    func joinConvoy(_ id: ConvoyID) async
    func leaveConvoy() async
    /// The convoy this device is in, nil when none (CNV). Replays the current value to each new
    /// consumer, then follows `joinConvoy`, `leaveConvoy`, and the gateway's `ConvoyState`
    /// frames (an ended convoy becomes nil). Until the first frame after `joinConvoy` the state
    /// carries only the id.
    func activeConvoy() async -> AsyncStream<ConvoyState?>
    func currentConvoy() async -> ConvoyState?
    /// Emits when the gateway closes the connection with reason "suspended" (SAFE-7). The
    /// client stops reconnecting; the shell signs out and shows `AccountSuspension.message`.
    func suspensions() async -> AsyncStream<Void>
}

public extension RealtimeService {
    /// Previews and fakes are never suspended.
    func suspensions() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// SAFE-7: the sign-in screen shows this after the shell signs a suspended account out.
public enum AccountSuspension {
    public static let message = "This account is suspended. Write to support@waypoints.app."
    /// Set by the shell when the gateway reports a suspension; read and cleared by sign-in.
    public static let defaultsKey = "account.suspended"
}

public enum ServerEvent: Sendable {
    case entities([EntityUpdate])          // conflated positions
    case gone([RealtimeUID])
    case aggregates([CellAggregate])       // low-zoom counts
    case mapEvent(MapEvent)                // report or meet created, changed, removed
    case convoy(ConvoyState)
}

public enum ConnectionState: Sendable { case connecting, live, reconnecting(attempt: Int), offline }
