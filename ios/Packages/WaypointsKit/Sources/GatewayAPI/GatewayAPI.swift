import Core

/// HTTPS client for the Go gateway's JSON API (plan section 6).
/// Stub from W0-A: returns the preview implementation until W1-3 replaces it.
public enum GatewayAPI {
    public static func makeLive(config: AppConfig, auth: any AuthService) -> any GatewayService {
        PreviewStore.shared
    }
}
