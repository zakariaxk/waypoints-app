import Core
import DesignSystem
import SwiftUI

/// Earned marker icons and trails (plan 9.8). Shows a newly earned unlock in the map sheet with
/// the `win` moment and lets the user put it on straight away. Locked icons with exact progress
/// live in the marker picker (M10).
public enum ProgressFeature: FeatureModule {
    public static let isAvailable = true

    @MainActor
    public static func register(in registry: FeatureRegistry, env: AppEnvironment) {
        registry.registerMapSheetSection(UnlockSection(env: env))
    }

    /// Which icon or trail each key unlocks.
    static let unlocks: [String: (name: String, trail: Bool)] = [
        "first_meet": ("lowrider", false), "host_3": ("safety_car", false), "reports_10": ("rally", false),
        "reports_50": ("lifted_truck", false), "spots_25": ("shooting_brake", false), "spots_100": ("woody_wagon", false),
        "roads_5": ("targa", false), "build_10": ("restomod", false), "showdown_top10": ("wide_body", false),
        "convoy_lead": ("flatbed", false), "strip_12s": ("drift", false), "strip_10s": ("time_attack", false),
        "teams_join": ("dually", false), "meets_5": ("fastback_classic", false), "friends_5": ("microcar", false),
        "convoy_3": ("van_camper", false), "listing_1": ("ute", false), "showdown_50": ("gt_wing_hatch", false),
        "build_25": ("rat_rod", false), "venue_5": ("box_truck", false), "reports_1": ("dash", true),
        "meets_1": ("double", true), "convoy_1": ("chevrons", true), "spots_5": ("dots", true),
        "strip_1": ("checker", true), "roads_1": ("tread", true), "posts_5": ("comet", true),
    ]
}

struct UnlockSection: MapSheetSection {
    let env: AppEnvironment
    var id: String { "unlocks" }
    var order: Int { 1 }
    @MainActor func view(region: MapRegion) -> AnyView { AnyView(UnlockView(env: env)) }
}

struct UnlockView: View {
    let env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("progress.seen") private var seenRaw = ""
    @State private var fresh: (key: String, name: String, trail: Bool)?
    @State private var shown = false

    var body: some View {
        Group {
            if let f = fresh {
                HStack(spacing: Space.s12) {
                    if !f.trail {
                        SilhouetteIcon(f.name, paint: .sodium).frame(width: Size.Marker.friend, height: Size.Marker.friend)
                            .scaleEffect(shown || reduceMotion ? 1 : 0.4)
                            .opacity(shown ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: Space.s2) {
                        (f.trail ? Text("New trail", bundle: .module) : Text("New icon", bundle: .module)).typeStyle(.label).foregroundStyle(Color.sodium)
                        Text(verbatim: MapIconSet.title(f.name)).typeStyle(.bodyStrong).foregroundStyle(Color.chalk)
                    }
                    Spacer()
                    QuietButton("Use it") {
                        let update = f.trail ? ProfileUpdate(markerTrail: f.name) : ProfileUpdate(markerIcon: f.name)
                        Task { _ = try? await env.profiles.updateMyProfile(update) }
                        dismiss(f.key)
                    }
                    IconButton(Symbol.close, label: "Dismiss") { dismiss(f.key) }
                }
                .padding(.horizontal, Space.margin)
                .padding(.vertical, Space.s8)
                .onAppear { withMotion(.win, reduceMotion: reduceMotion) { shown = true } }
            }
        }
        .task {
            let seen = Set(seenRaw.split(separator: ",").map(String.init))
            let earned = ((try? await env.progress.myProgress()) ?? []).filter { $0.earnedAt != nil }.map(\.key)
            if seenRaw.isEmpty {
                seenRaw = earned.joined(separator: ",")       // first launch: nothing is "new"
                return
            }
            if let key = earned.first(where: { !seen.contains($0) }), let u = ProgressFeature.unlocks[key] {
                fresh = (key, u.name, u.trail)
            }
        }
    }

    private func dismiss(_ key: String) {
        seenRaw = (seenRaw.isEmpty ? [] : seenRaw.split(separator: ",").map(String.init)).appending(key).joined(separator: ",")
        fresh = nil
    }
}

private extension Array {
    func appending(_ e: Element) -> [Element] { self + [e] }
}
