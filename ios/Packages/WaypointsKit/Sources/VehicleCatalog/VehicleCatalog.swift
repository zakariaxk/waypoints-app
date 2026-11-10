import Core

/// SQLite catalog reader, search, update check, and the vehicle picker (plan section 11.1).
/// Stub from W0-A: returns the seed catalog until W1-6 replaces it.
public enum VehicleCatalog {
    public static func makeLive(config: AppConfig) -> any VehicleCatalogService {
        PreviewVehicleCatalogService()
    }
}
