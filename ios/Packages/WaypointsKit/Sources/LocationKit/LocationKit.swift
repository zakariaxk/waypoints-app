import Core

/// Location actor, adaptive sampler, home zones (plan sections 2.5 and 3.3).
public enum LocationKit {
    public static func makeLive(config: AppConfig) -> any LocationService {
        LiveLocationService()
    }
}
