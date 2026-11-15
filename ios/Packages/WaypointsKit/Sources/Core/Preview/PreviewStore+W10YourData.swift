import Foundation

/// ACC-12: the preview stand-in for `export_my_data`, built from the seeded rows the user owns.
extension PreviewStore {
    public func exportMyData() async throws -> Data {
        struct Export: Encodable {
            let profile: Profile?
            let privacySettings: PrivacySettings?
            let notificationSettings: NotificationPrefs
            let cars: [Car]
            let posts: [Post]
            let listings: [Listing]
            let messages: [Message]
        }
        let me = try me()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Export(
            profile: profiles[me],
            privacySettings: privacy[me],
            notificationSettings: notificationPrefs,
            cars: cars.values.filter { $0.ownerID == me }.sorted { $0.sort < $1.sort },
            posts: posts.values.filter { $0.authorID == me }.sorted { $0.createdAt < $1.createdAt },
            listings: listings.values.filter { $0.sellerID == me }.sorted { $0.createdAt < $1.createdAt },
            messages: messages.filter { $0.authorID == me && $0.deletedAt == nil }
        ))
    }
}
