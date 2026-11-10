import Foundation

/// Implemented by `RealtimeClient` (plan section 4.3).
public protocol RealtimeService: Sendable {
    func events() async -> AsyncStream<ServerEvent>          // multi-consumer: each call gets its own stream
    func connectionState() async -> AsyncStream<ConnectionState>
    func setViewport(_ region: MapRegion) async
    func send(_ sample: LocationSample) async
    func joinConvoy(_ id: ConvoyID) async
    func leaveConvoy() async
}

public enum ServerEvent: Sendable {
    case entities([EntityUpdate])          // conflated positions
    case gone([RealtimeUID])
    case aggregates([CellAggregate])       // low-zoom counts
    case mapEvent(MapEvent)                // report or meet created, changed, removed
    case convoy(ConvoyState)
}

public enum ConnectionState: Sendable { case connecting, live, reconnecting(attempt: Int), offline }
