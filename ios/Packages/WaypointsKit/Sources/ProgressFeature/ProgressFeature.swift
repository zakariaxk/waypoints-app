import Core

/// Entry point for `ProgressFeature`. Stub from W0-A: not built yet, so the shell hides it.
/// The owning work package replaces this file (plan section 12).
public enum ProgressFeature: FeatureModule {
    public static let isAvailable = false

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {}
}
