import Foundation

/// An in-memory `AppEnvironment` with realistic seed data (`PreviewSeed`), so every feature can
/// be built and previewed before `Backend` exists.
public enum PreviewEnvironment {
    /// A fresh, independent environment. Signed in as `PreviewSeed.me` unless `signedIn` is false.
    public static func make(signedIn: Bool = true, router: any Router = PreviewRouter()) -> AppEnvironment {
        make(store: PreviewStore(signedIn: signedIn), router: router)
    }

    public static func make(store: PreviewStore, router: any Router) -> AppEnvironment {
        AppEnvironment(
            auth: store, profiles: store, garage: store, friends: store, meets: store, reports: store,
            teams: store, messages: store, posts: store, showdown: store, market: store, spots: store,
            roads: store, progress: store, media: store,
            realtime: PreviewRealtimeService(), location: PreviewLocationService(), gateway: store,
            catalog: PreviewVehicleCatalogService(), safety: store, router: router,
            activity: PreviewActivity()
        )
    }
}

/// Router for previews: records what was opened.
@MainActor
public final class PreviewRouter: Router {
    public private(set) var opened: [Route] = []
    public nonisolated init() {}
    public func open(_ route: Route) { opened.append(route) }
}
