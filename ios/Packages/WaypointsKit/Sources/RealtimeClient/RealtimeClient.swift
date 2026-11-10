import Core
import WireProtocol

/// WebSocket actor, reconnect, `AsyncStream<ServerEvent>` (plan sections 3.2 and 6).
/// Stub from W0-A: returns the simulated feed until W1-3 replaces it.
public enum RealtimeClient {
    public static func makeLive(config: AppConfig, auth: any AuthService) -> any RealtimeService {
        PreviewRealtimeService()
    }
}
