import Core
import Foundation
import SQLite3

/// SQLite catalog reader, search, update check, and the vehicle picker (plan section 11.1).
public enum VehicleCatalog {
    /// The bundled `catalog.sqlite.lzfse`, expanded to Application Support on first run. Without
    /// a bundled catalog (it is built by `tools/catalog`) the seed catalog is used.
    public static func makeLive(config: AppConfig) -> any VehicleCatalogService {
        CatalogUpdater.swapInPending()
        if !config.supabaseAnonKey.isEmpty { CatalogUpdater.checkInBackground(config: config) }
        if let url = SQLiteCatalog.installedURL() { return SQLiteCatalog(url: url) }
        return PreviewVehicleCatalogService()
    }
}

/// `VehicleCatalogService` over the catalog database built by `tools/catalog`.
actor SQLiteCatalog: VehicleCatalogService {
    private var db: OpaquePointer?
    private let url: URL

    init(url: URL) { self.url = url }

    /// Expands the bundled snapshot once; returns nil when the app ships without one.
    static func installedURL() -> URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let target = support.appending(path: "catalog.sqlite")
        if fm.fileExists(atPath: target.path) { return target }
        if let raw = Bundle.main.url(forResource: "catalog", withExtension: "sqlite") {
            try? fm.copyItem(at: raw, to: target)
        } else if let packed = Bundle.main.url(forResource: "catalog.sqlite", withExtension: "lzfse"),
                  let data = try? Data(contentsOf: packed),
                  let expanded = try? (data as NSData).decompressed(using: .lzfse) as Data {
            try? expanded.write(to: target, options: .atomic)
        }
        return fm.fileExists(atPath: target.path) ? target : nil
    }

    private func open() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw WaypointsError.server("catalog unavailable")
        }
        db = handle
        return handle
    }

    private enum Bind { case int(Int64), text(String) }

    private func query<T>(_ sql: String, _ binds: [Bind] = [], row: (OpaquePointer) -> T) throws -> [T] {
        let db = try open()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WaypointsError.server(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            switch b {
            case let .int(v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case let .text(v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
            }
        }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i))
    }
    private static func int(_ s: OpaquePointer, _ i: Int32) -> Int? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
    }

    private static let variantSQL = """
        SELECT v.id, v.model_id, mk.name, m.name, v.year, v.trim, v.engine, v.displacement_l, v.cylinders,
               v.aspiration, v.drive, v.transmission, v.hp, v.torque_lbft, v.weight_lb, v.redline, v.gears_json, v.spec_source
        FROM variant v JOIN model m ON m.id = v.model_id JOIN make mk ON mk.id = m.make_id
        """

    private static func variant(_ s: OpaquePointer) -> CatalogVariant {
        let gears = text(s, 16).flatMap { try? JSONDecoder().decode([Double].self, from: Data($0.utf8)) }
        return CatalogVariant(
            id: sqlite3_column_int64(s, 0), modelID: sqlite3_column_int64(s, 1), make: text(s, 2) ?? "", model: text(s, 3) ?? "",
            year: int(s, 4) ?? 0, trim: text(s, 5), engine: text(s, 6),
            displacementL: sqlite3_column_type(s, 7) == SQLITE_NULL ? nil : sqlite3_column_double(s, 7),
            cylinders: int(s, 8), aspiration: text(s, 9).flatMap(Aspiration.init(rawValue:)),
            drive: text(s, 10).flatMap(Drivetrain.init(rawValue:)), transmission: text(s, 11), hp: int(s, 12),
            torqueLbFt: int(s, 13), weightLb: int(s, 14), redline: int(s, 15), gears: gears, specSource: text(s, 17))
    }

    func search(_ query: String, limit: Int) async throws -> [CatalogVariant] {
        var year: Int?
        var words: [String] = []
        for token in query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            if token.count == 4, let y = Int(token), (1950...2030).contains(y) { year = y } else { words.append(token) }
        }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        var sql = Self.variantSQL + " WHERE v.id IN (SELECT rowid FROM variant_fts WHERE variant_fts MATCH ?)"
        var binds: [Bind] = [.text(match)]
        if let year { sql += " AND v.year = ?"; binds.append(.int(Int64(year))) }
        sql += " ORDER BY v.year DESC, v.hp DESC LIMIT ?"
        binds.append(.int(Int64(limit)))
        return try self.query(sql, binds, row: Self.variant)
    }

    func popularMakes() async throws -> [CatalogMake] {
        try query("SELECT id, name FROM make WHERE popular_rank > 0 ORDER BY popular_rank LIMIT 12") {
            CatalogMake(id: sqlite3_column_int64($0, 0), name: Self.text($0, 1) ?? "")
        }
    }

    func makes() async throws -> [CatalogMake] {
        try query("SELECT id, name FROM make ORDER BY name") {
            CatalogMake(id: sqlite3_column_int64($0, 0), name: Self.text($0, 1) ?? "")
        }
    }

    func models(of make: Int64) async throws -> [CatalogModel] {
        try query("SELECT id, make_id, name, year_from, year_to FROM model WHERE make_id = ? ORDER BY year_to DESC, name",
                  [.int(make)]) {
            CatalogModel(id: sqlite3_column_int64($0, 0), makeID: sqlite3_column_int64($0, 1), name: Self.text($0, 2) ?? "",
                         yearFrom: Self.int($0, 3) ?? 0, yearTo: Self.int($0, 4) ?? 0)
        }
    }

    func years(of model: Int64) async throws -> [Int] {
        try query("SELECT DISTINCT year FROM variant WHERE model_id = ? ORDER BY year DESC", [.int(model)]) {
            Self.int($0, 0) ?? 0
        }
    }

    func variants(of model: Int64, year: Int) async throws -> [CatalogVariant] {
        try query(Self.variantSQL + " WHERE v.model_id = ? AND v.year = ? ORDER BY v.hp", [.int(model), .int(Int64(year))],
                  row: Self.variant)
    }

    func variant(_ id: Int64) async throws -> CatalogVariant? {
        try query(Self.variantSQL + " WHERE v.id = ?", [.int(id)], row: Self.variant).first
    }

    func decodeVIN(_ vin: String) async throws -> VINDecode {
        try await VINDecoder.decode(vin) { year, make, model in
            guard let year, let make, let model else { return nil }
            return try? await self.search("\(year) \(make) \(model)", limit: 1).first?.id
        }
    }
}

/// vPIC `DecodeVinValues`.
enum VINDecoder {
    static func decode(_ vin: String, match: @Sendable (Int?, String?, String?) async -> Int64?) async throws -> VINDecode {
        let clean = vin.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count == 17 else { throw WaypointsError.invalid("vin") }
        let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/\(clean)?format=json")!
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: url) } catch { throw WaypointsError.offline }
        struct Response: Decodable {
            struct Result: Decodable {
                let ModelYear: String?, Make: String?, Model: String?, Trim: String?
            }
            let Results: [Result]
        }
        guard let r = try JSONDecoder().decode(Response.self, from: data).Results.first else { throw WaypointsError.notFound }
        func titled(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0.capitalized } }
        let year = r.ModelYear.flatMap(Int.init)
        let make = titled(r.Make), model = r.Model.flatMap { $0.isEmpty ? nil : $0 }
        return VINDecode(year: year, make: make, model: model, trim: r.Trim.flatMap { $0.isEmpty ? nil : $0 },
                         variantID: await match(year, make, model))
    }
}
