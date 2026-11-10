import Core
import Foundation
import Supabase

/// `cars`, `car_photos`, `build_entries`.
struct LiveGarage: GarageRepository {
    let ctx: BackendContext
    /// One fan-out per owner; created on first subscription.
    let changes: FanoutTable<UserID, [Car]>

    func cars(of owner: UserID) async throws -> [Car] {
        try await ctx.run {
            let rows: [CarRow] = try await ctx.table("cars").select().eq("owner_id", value: owner.key)
                .order("sort").order("created_at").execute().value
            return rows.map(\.car)
        }
    }

    func car(_ id: CarID) async throws -> Car {
        try await ctx.run {
            let row: CarRow = try await ctx.table("cars").select().eq("id", value: id.key).single().execute().value
            return row.car
        }
    }

    func createCar(_ car: NewCar) async throws -> Car {
        let me = try ctx.me()
        let existing = try await cars(of: me)
        let created = try await ctx.run {
            let row: CarRow = try await ctx.table("cars")
                .insert(CarWrite(car, owner: me, sort: (existing.map(\.sort).max() ?? -1) + 1), returning: .representation)
                .select().single().execute().value
            return row.car
        }
        await publish(me)
        return created
    }

    func updateCar(_ car: Car) async throws -> Car {
        let updated = try await ctx.run {
            let row: CarRow = try await ctx.table("cars").update(CarWrite(car)).eq("id", value: car.id.key)
                .select().single().execute().value
            return row.car
        }
        await publish(updated.ownerID)
        return updated
    }

    func deleteCar(_ id: CarID) async throws {
        let me = try ctx.me()
        try await ctx.run {
            _ = try await ctx.table("cars").delete(returning: .minimal).eq("id", value: id.key).execute()
        }
        await publish(me)
    }

    func reorderCars(_ ids: [CarID]) async throws {
        let me = try ctx.me()
        struct Body: Encodable { let sort: Int }
        try await ctx.run {
            for (index, id) in ids.enumerated() {
                try await ctx.table("cars").update(Body(sort: index), returning: .minimal)
                    .eq("id", value: id.key).execute()
            }
        }
        await publish(me)
    }

    func photos(of car: CarID) async throws -> [CarPhoto] {
        try await ctx.run {
            let rows: [CarPhotoRow] = try await ctx.table("car_photos").select().eq("car_id", value: car.key)
                .order("sort").order("created_at").execute().value
            return rows.map(\.model)
        }
    }

    func addPhoto(to car: CarID, media: StoredMedia) async throws -> CarPhoto {
        let existing = try await photos(of: car)
        struct Body: Encodable { let carId: UUID; let path: String; let width: Int?; let height: Int?; let sort: Int }
        let body = Body(carId: car.raw, path: media.path, width: media.width.flatMap { $0 > 0 ? $0 : nil },
                        height: media.height.flatMap { $0 > 0 ? $0 : nil }, sort: (existing.map(\.sort).max() ?? -1) + 1)
        return try await ctx.run {
            let row: CarPhotoRow = try await ctx.table("car_photos").insert(body, returning: .representation)
                .select().single().execute().value
            return row.model
        }
    }

    func removePhoto(_ id: CarPhotoID) async throws {
        try await ctx.run {
            _ = try await ctx.table("car_photos").delete(returning: .minimal).eq("id", value: id.key).execute()
        }
    }

    func reorderPhotos(of car: CarID, _ ids: [CarPhotoID]) async throws {
        struct Body: Encodable { let sort: Int }
        try await ctx.run {
            for (index, id) in ids.enumerated() {
                try await ctx.table("car_photos").update(Body(sort: index), returning: .minimal)
                    .eq("id", value: id.key).eq("car_id", value: car.key).execute()
            }
        }
    }

    func buildEntries(of car: CarID) async throws -> [BuildEntry] {
        try await ctx.run {
            let rows: [BuildEntryRow] = try await ctx.table("build_entries").select().eq("car_id", value: car.key)
                .order("happened_on", ascending: false).order("created_at", ascending: false).execute().value
            return rows.map(\.model)
        }
    }

    func addBuildEntry(_ entry: BuildEntry) async throws -> BuildEntry {
        try await ctx.run {
            let row: BuildEntryRow = try await ctx.table("build_entries")
                .insert(BuildEntryWrite(entry), returning: .representation).select().single().execute().value
            return row.model
        }
    }

    func updateBuildEntry(_ entry: BuildEntry) async throws -> BuildEntry {
        try await ctx.run {
            let row: BuildEntryRow = try await ctx.table("build_entries").update(BuildEntryWrite(entry))
                .eq("id", value: entry.id.key).select().single().execute().value
            return row.model
        }
    }

    func deleteBuildEntry(_ id: BuildEntryID) async throws {
        try await ctx.run {
            _ = try await ctx.table("build_entries").delete(returning: .minimal).eq("id", value: id.key).execute()
        }
    }

    /// Cars are not in the Realtime publication: the stream re-emits after this device's
    /// own changes and on each new subscription.
    func carChanges(of owner: UserID) async -> AsyncStream<[Car]> {
        let fanout = await changes.fanout(for: owner)
        let stream = await fanout.subscribe()
        await publish(owner)
        return stream
    }

    private func publish(_ owner: UserID) async {
        guard let fanout = await changes.existing(for: owner), let list = try? await cars(of: owner) else { return }
        await fanout.send(list)
    }
}
