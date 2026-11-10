import Foundation

/// `cars`, `car_photos`, `build_entries`. Section 5.2.
public protocol GarageRepository: Sendable {
    func cars(of owner: UserID) async throws -> [Car]
    func car(_ id: CarID) async throws -> Car
    @discardableResult func createCar(_ car: NewCar) async throws -> Car
    @discardableResult func updateCar(_ car: Car) async throws -> Car
    func deleteCar(_ id: CarID) async throws
    func reorderCars(_ ids: [CarID]) async throws

    func photos(of car: CarID) async throws -> [CarPhoto]
    @discardableResult func addPhoto(to car: CarID, media: StoredMedia) async throws -> CarPhoto
    func removePhoto(_ id: CarPhotoID) async throws
    func reorderPhotos(of car: CarID, _ ids: [CarPhotoID]) async throws

    func buildEntries(of car: CarID) async throws -> [BuildEntry]
    @discardableResult func addBuildEntry(_ entry: BuildEntry) async throws -> BuildEntry
    @discardableResult func updateBuildEntry(_ entry: BuildEntry) async throws -> BuildEntry
    func deleteBuildEntry(_ id: BuildEntryID) async throws

    /// Emits the owner's full car list whenever it changes.
    func carChanges(of owner: UserID) async -> AsyncStream<[Car]>
}
