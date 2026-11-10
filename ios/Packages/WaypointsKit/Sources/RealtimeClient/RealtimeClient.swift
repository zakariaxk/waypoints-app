import Core
import WireProtocol

/// WebSocket actor, reconnect, `AsyncStream<ServerEvent>` (plan sections 3.2 and 6).
public enum RealtimeClient {
    /// Pass `location` so home zones reach the gateway at every connect and on every change
    /// (plan section 4.3).
    public static func makeLive(config: AppConfig, auth: any AuthService,
                                location: (any LocationService)? = nil) -> any RealtimeService {
        let service = LiveRealtimeService(config: config, auth: auth, location: location)
        Task { await service.start() }
        return service
    }
}
