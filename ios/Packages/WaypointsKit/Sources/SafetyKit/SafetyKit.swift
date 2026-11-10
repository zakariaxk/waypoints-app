import Core

/// Report and block flows, text filter, terms gate (plan section 10.10).
/// Stub from W0-A: returns the preview implementation until W1-4 and W2-7 replace it.
public enum SafetyKit {
    public static func makeLive(config: AppConfig) -> any SafetyService {
        PreviewStore.shared
    }
}
