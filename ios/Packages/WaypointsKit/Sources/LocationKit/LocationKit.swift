import Core

/// Location actor, adaptive sampler, home zones (plan sections 2.5 and 3.3).
/// Stub from W0-A: returns the simulated location until W1-3 replaces it.
public enum LocationKit {
    public static func makeLive(config: AppConfig) -> any LocationService {
        PreviewLocationService(authorization: .notDetermined)
    }
}
