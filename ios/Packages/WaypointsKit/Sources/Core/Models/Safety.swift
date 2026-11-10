import Foundation

// Section 5.5: content reports. Section 10.10: X1.

public enum ContentKind: String, Sendable, Codable, Hashable, CaseIterable {
    case user, car, post, comment, message, listing, meet, report, team, spot, road
}

/// A pointer to any reportable thing (`content_reports.target_kind`, `target_id`).
public struct ContentRef: Hashable, Sendable, Codable {
    public var kind: ContentKind
    public var id: String
    public init(kind: ContentKind, id: String) { self.kind = kind; self.id = id }
    public static func user(_ id: UserID) -> ContentRef { .init(kind: .user, id: id.description) }
}

public enum ContentReportReason: String, Sendable, Codable, Hashable, CaseIterable {
    case spam, harassment, nudity, dangerousDriving = "dangerous_driving", scam, other
}

public enum TextCheck: Hashable, Sendable {
    case ok
    case blocked(reason: String)
}
