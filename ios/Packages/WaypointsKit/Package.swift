// swift-tools-version: 6.0
// Waypoints client modules. Layout and layer rules: docs/PLAN.md section 4.1.
// Only W0-A and integration packages edit this file (plan section 4.2).

import PackageDescription

// Layer 1 libraries any feature may use. Infrastructure clients (Backend, GatewayAPI,
// RealtimeClient, LocationKit) are reached by features only through `Core` protocols in
// `AppEnvironment`, so features do not depend on them.
let featureDependencies: [Target.Dependency] = [
    "Core", "DesignSystem", "SafetyKit", "VehicleCatalog", "PerformanceModel", "EngineAudio",
]

let featureNames = [
    "MapFeature", "NavigationFeature", "ReportsFeature", "MeetsFeature", "ConvoyFeature",
    "MessagingFeature", "TeamsFeature", "VoiceFeature", "FeedFeature", "ShowdownFeature",
    "GarageFeature", "ModSimFeature", "RaceFeature", "MarketFeature", "SpotsFeature",
    "RoadsFeature", "ProgressFeature", "OnboardingFeature", "SettingsFeature", "PushKitBridge",
]

let infrastructure: [Target] = [
    // Layer 0
    .target(name: "Core"),
    .target(name: "WireProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
    // Layer 1
    // Resources: the embedded B612 Mono readout face and its licence (W0-D).
    .target(name: "DesignSystem", resources: [.copy("Resources/Fonts")]),
    .target(name: "Backend", dependencies: ["Core", .product(name: "Supabase", package: "supabase-swift")]),
    .target(name: "GatewayAPI", dependencies: ["Core"]),
    .target(name: "RealtimeClient", dependencies: ["Core", "WireProtocol"]),
    .target(name: "LocationKit", dependencies: ["Core"]),
    // GRDB.swift (plan 4.4) is added here by W1-6 together with the catalog reader.
    .target(name: "VehicleCatalog", dependencies: ["Core", "DesignSystem"]),
    .target(name: "PerformanceModel", dependencies: ["Core"]),
    .target(name: "EngineAudio", dependencies: ["Core"]),
    .target(name: "SafetyKit", dependencies: ["Core", "DesignSystem"]),
]

// LiveKit client-sdk-swift (plan 4.4) goes to VoiceFeature only: it ships a large WebRTC binary.
let features: [Target] = featureNames.map { name in
    name == "VoiceFeature"
        ? .target(name: name, dependencies: featureDependencies + [.product(name: "LiveKit", package: "client-sdk-swift")])
        : .target(name: name, dependencies: featureDependencies)
}

// Layer 3
let shell: Target = .target(
    name: "AppShell",
    dependencies: ["Core", "DesignSystem"] + featureNames.map { Target.Dependency(stringLiteral: $0) }
)

let allTargets = infrastructure + features + [shell]

let package = Package(
    name: "WaypointsKit",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "WaypointsKit", targets: allTargets.map(\.name)),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.19.0"),
    ],
    targets: allTargets,
    swiftLanguageModes: [.v6]
)
