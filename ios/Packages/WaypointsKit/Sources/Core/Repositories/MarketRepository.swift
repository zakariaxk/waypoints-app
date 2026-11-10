import Foundation

/// `listings`, `listing_photos`, `listing_saves`. Section 5.5.
public protocol MarketRepository: Sendable {
    func listings(_ filter: ListingFilter, after cursor: PageCursor?, limit: Int) async throws -> Page<Listing>
    func listing(_ id: ListingID) async throws -> Listing
    func listings(by seller: UserID) async throws -> [Listing]
    @discardableResult func createListing(_ draft: ListingDraft) async throws -> Listing
    @discardableResult func updateListing(_ listing: Listing) async throws -> Listing
    func setStatus(_ status: ListingStatus, for id: ListingID) async throws
    func save(_ id: ListingID) async throws
    func unsave(_ id: ListingID) async throws
    func savedListings() async throws -> [Listing]
}
