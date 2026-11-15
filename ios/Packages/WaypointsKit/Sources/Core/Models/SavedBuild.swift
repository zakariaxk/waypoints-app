import Foundation

/// MOD-15: a named mod set kept with a car (`cars.saved_builds`). A car holds at most `limit`.
public struct SavedBuild: Identifiable, Hashable, Sendable, Codable {
    public static let limit = 3
    public static let nameLimit = 30

    public let id: UUID
    public var name: String                   // ≤30
    public var mods: [String]                 // mod ids from tools/mods

    public init(id: UUID = UUID(), name: String, mods: [String]) {
        self.id = id; self.name = name; self.mods = mods
    }
}
