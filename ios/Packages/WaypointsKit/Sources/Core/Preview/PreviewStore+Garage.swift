import Foundation

extension PreviewStore: GarageRepository {
    public func cars(of owner: UserID) async throws -> [Car] {
        guard visible(owner) else { return [] }
        return carList(of: owner)
    }
    public func car(_ id: CarID) async throws -> Car {
        guard let car = cars[id], visible(car.ownerID) else { throw WaypointsError.notFound }
        return car
    }
    public func createCar(_ new: NewCar) async throws -> Car {
        let me = try me()
        let car = Car(ownerID: me, catalogVariantID: new.catalogVariantID, year: new.year, make: new.make,
                      model: new.model, trim: new.trim, nickname: new.nickname, colorFamily: new.colorFamily,
                      colorHex: new.colorHex, paintName: new.paintName, clearance: new.clearance,
                      sort: carList(of: me).count)
        cars[car.id] = car
        if var profile = profiles[me], profile.primaryCarID == nil {
            profile.primaryCarID = car.id
            profileChanged(profile)
        }
        carsChanged(of: me)
        return car
    }
    public func updateCar(_ car: Car) async throws -> Car {
        let me = try me()
        guard cars[car.id]?.ownerID == me else { throw WaypointsError.forbidden }
        cars[car.id] = car
        carsChanged(of: car.ownerID)
        return car
    }
    public func deleteCar(_ id: CarID) async throws {
        let me = try me()
        guard cars[id]?.ownerID == me else { throw WaypointsError.forbidden }
        cars[id] = nil
        carPhotos.removeAll { $0.carID == id }
        buildEntries.removeAll { $0.carID == id }
        carsChanged(of: me)
    }
    public func reorderCars(_ ids: [CarID]) async throws {
        let me = try me()
        for (index, id) in ids.enumerated() where cars[id]?.ownerID == me { cars[id]?.sort = index }
        carsChanged(of: me)
    }

    public func photos(of car: CarID) async throws -> [CarPhoto] {
        carPhotos.filter { $0.carID == car }.sorted { $0.sort < $1.sort }
    }
    public func addPhoto(to car: CarID, media: StoredMedia) async throws -> CarPhoto {
        let photo = CarPhoto(carID: car, path: media.path, width: media.width ?? 0, height: media.height ?? 0,
                             sort: carPhotos.filter { $0.carID == car }.count)
        carPhotos.append(photo)
        return photo
    }
    public func removePhoto(_ id: CarPhotoID) async throws { carPhotos.removeAll { $0.id == id } }
    public func reorderPhotos(of car: CarID, _ ids: [CarPhotoID]) async throws {
        for (index, id) in ids.enumerated() {
            if let i = carPhotos.firstIndex(where: { $0.id == id && $0.carID == car }) { carPhotos[i].sort = index }
        }
    }

    public func buildEntries(of car: CarID) async throws -> [BuildEntry] {
        buildEntries.filter { $0.carID == car }.sorted { $0.happenedOn > $1.happenedOn }
    }
    public func addBuildEntry(_ entry: BuildEntry) async throws -> BuildEntry {
        buildEntries.append(entry)
        return entry
    }
    public func updateBuildEntry(_ entry: BuildEntry) async throws -> BuildEntry {
        guard let i = buildEntries.firstIndex(where: { $0.id == entry.id }) else { throw WaypointsError.notFound }
        buildEntries[i] = entry
        return entry
    }
    public func deleteBuildEntry(_ id: BuildEntryID) async throws { buildEntries.removeAll { $0.id == id } }

    public func carChanges(of owner: UserID) async -> AsyncStream<[Car]> {
        carBroadcasts[owner, default: Broadcast()].subscribe(initial: carList(of: owner))
    }
}

extension PreviewStore: MediaStore {
    public func upload(_ data: Data, contentType: String, to bucket: MediaBucket,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> StoredMedia {
        let me = try me()
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(150))
            progress(Double(step) / 4)
        }
        let ext = contentType.split(separator: "/").last.map(String.init) ?? "bin"
        return StoredMedia(bucket: bucket, path: "\(me)/\(UUID().uuidString.lowercased()).\(ext)")
    }
    public func delete(_ media: StoredMedia) async throws {}
    public nonisolated func publicURL(bucket: MediaBucket, path: String) -> URL {
        URL(string: "https://preview.waypoints.invalid/storage/v1/object/public/\(bucket.rawValue)/\(path)")!
    }
}

extension PreviewStore: SpotRepository {
    public func spots(by spotter: UserID) async throws -> [Spot] {
        spots.filter { $0.spotterID == spotter }.sorted { $0.createdAt > $1.createdAt }
    }
    public func addSpot(_ spot: Spot) async throws -> Spot { spots.append(spot); return spot }
    public func deleteSpot(_ id: SpotID) async throws { spots.removeAll { $0.id == id } }
}

extension PreviewStore: ProgressRepository {
    public func achievements(of user: UserID) async throws -> [Achievement] {
        achievements.filter { $0.userID == user }
    }
    public func myProgress() async throws -> [AchievementProgress] {
        let me = try me()
        let earned = Dictionary(achievements.filter { $0.userID == me }.map { ($0.key, $0.earnedAt) }) { a, _ in a }
        let confirmed = reports.values.filter { $0.authorID == me && $0.confirmations > 1 }.count
        let distinctSpots = Set(spots.filter { $0.spotterID == me }.map(\.catalogModelID)).count
        let rated = roadRatings.keys.filter { $0.b == me.raw }.count
        let longestBuild = carList(of: me).map { car in buildEntries.filter { $0.carID == car.id }.count }.max() ?? 0
        let targets: [(String, Int, Int)] = [
            ("first_meet", earned["first_meet"] == nil ? 0 : 1, 1),
            ("host_3", 0, 3),
            ("reports_10", confirmed, 10),
            ("reports_50", confirmed, 50),
            ("spots_25", distinctSpots, 25),
            ("spots_100", distinctSpots, 100),
            ("roads_5", rated, 5),
            ("build_10", longestBuild, 10),
            ("showdown_top10", 0, 1),
            ("convoy_lead", 0, 1),
            ("strip_12s", 0, 1),
            ("strip_10s", 0, 1),
        ]
        return targets.map { AchievementProgress(key: $0.0, current: min($0.1, $0.2), target: $0.2, earnedAt: earned[$0.0]) }
    }
    public func saveRaceResult(_ result: RaceResult) async throws -> RaceResult {
        raceResults.append(result)
        return result
    }
    public func raceResults(for car: CarID) async throws -> [RaceResult] {
        raceResults.filter { $0.carID == car }.sorted { $0.etMs < $1.etMs }
    }
    public func bestRaceResults(limit: Int) async throws -> [RaceResult] {
        Array(raceResults.sorted { $0.etMs < $1.etMs }.prefix(limit))
    }
}
