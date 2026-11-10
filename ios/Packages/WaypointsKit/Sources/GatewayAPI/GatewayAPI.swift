import Core
import Foundation

/// HTTPS client for the Go gateway's JSON API (plan section 6).
public enum GatewayAPI {
    public static func makeLive(config: AppConfig, auth: any AuthService) -> any GatewayService {
        LiveGatewayService(baseURL: config.gatewayURL, auth: auth)
    }
}
