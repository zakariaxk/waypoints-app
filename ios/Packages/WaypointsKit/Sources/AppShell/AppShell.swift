import Core
import ConvoyFeature
import FeedFeature
import GarageFeature
import MapFeature
import MarketFeature
import MeetsFeature
import MessagingFeature
import ModSimFeature
import NavigationFeature
import OnboardingFeature
import ProgressFeature
import PushKitBridge
import RaceFeature
import ReportsFeature
import RoadsFeature
import SettingsFeature
import ShowdownFeature
import SpotsFeature
import TeamsFeature
import VoiceFeature

/// Tab container, router, deep links, and plug-in registry (plan 4.1, layer 3).
/// The shell knows features only as `FeatureModule` types; it has no feature-specific code.
public enum AppShell {
    /// Every feature module in plan 4.1. Unavailable ones are skipped, so their tabs, routes,
    /// and map plug-ins simply do not exist.
    @MainActor
    public static func registerFeatures(in registry: FeatureRegistry, env: AppEnvironment) {
        let modules: [any FeatureModule.Type] = [
            MapFeature.self, NavigationFeature.self, ReportsFeature.self, MeetsFeature.self,
            ConvoyFeature.self, MessagingFeature.self, TeamsFeature.self, VoiceFeature.self,
            FeedFeature.self, ShowdownFeature.self, GarageFeature.self, ModSimFeature.self,
            RaceFeature.self, MarketFeature.self, SpotsFeature.self, RoadsFeature.self,
            ProgressFeature.self, OnboardingFeature.self, SettingsFeature.self, PushKitBridge.self,
        ]
        for module in modules where module.isAvailable {
            module.register(in: registry, env: env)
        }
    }
}
