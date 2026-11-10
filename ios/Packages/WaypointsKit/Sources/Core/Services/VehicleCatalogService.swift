import Foundation

/// The bundled vehicle catalog (section 11.1), implemented by `VehicleCatalog`.
public protocol VehicleCatalogService: Sendable {
    /// Free-text search like "2019 mustang gt"; tokens in any order.
    func search(_ query: String, limit: Int) async throws -> [CatalogVariant]
    func popularMakes() async throws -> [CatalogMake]
    func makes() async throws -> [CatalogMake]
    func models(of make: Int64) async throws -> [CatalogModel]
    func years(of model: Int64) async throws -> [Int]
    func variants(of model: Int64, year: Int) async throws -> [CatalogVariant]
    func variant(_ id: Int64) async throws -> CatalogVariant?
    /// vPIC `DecodeVinValues`; needs a connection.
    func decodeVIN(_ vin: String) async throws -> VINDecode
}
