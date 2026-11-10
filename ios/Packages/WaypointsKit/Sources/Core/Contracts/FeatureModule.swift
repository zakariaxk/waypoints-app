import Foundation

/// Feature entry point: every feature module exposes one value conforming to this (plan 4.3).
public protocol FeatureModule: Sendable {
    static var isAvailable: Bool { get }
    @MainActor static func register(in registry: FeatureRegistry, env: AppEnvironment)
}
