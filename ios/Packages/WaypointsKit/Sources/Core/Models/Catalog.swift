import Foundation

// Section 11.1: rows of the bundled catalog.sqlite.

public struct CatalogMake: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public var name: String
    public init(id: Int64, name: String) { self.id = id; self.name = name }
}

public struct CatalogModel: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public let makeID: Int64
    public var name: String
    public var yearFrom: Int
    public var yearTo: Int
    public init(id: Int64, makeID: Int64, name: String, yearFrom: Int, yearTo: Int) {
        self.id = id; self.makeID = makeID; self.name = name; self.yearFrom = yearFrom; self.yearTo = yearTo
    }
}

public enum Aspiration: String, Sendable, Codable, Hashable { case natural, turbo, supercharged, twinCharged = "twincharged" }

public struct CatalogVariant: Identifiable, Hashable, Sendable, Codable {
    public let id: Int64
    public let modelID: Int64
    public var make: String
    public var model: String
    public var year: Int
    public var trim: String?
    public var engine: String?                // "5.0 L V8"
    public var displacementL: Double?
    public var cylinders: Int?
    public var aspiration: Aspiration?
    public var drive: Drivetrain?
    public var transmission: String?
    public var hp: Int?
    public var torqueLbFt: Int?
    public var weightLb: Int?
    public var redline: Int?
    public var gears: [Double]?
    public var specSource: String?
    public init(id: Int64, modelID: Int64, make: String, model: String, year: Int, trim: String? = nil,
                engine: String? = nil, displacementL: Double? = nil, cylinders: Int? = nil,
                aspiration: Aspiration? = nil, drive: Drivetrain? = nil, transmission: String? = nil,
                hp: Int? = nil, torqueLbFt: Int? = nil, weightLb: Int? = nil, redline: Int? = nil,
                gears: [Double]? = nil, specSource: String? = nil) {
        self.id = id; self.modelID = modelID; self.make = make; self.model = model; self.year = year
        self.trim = trim; self.engine = engine; self.displacementL = displacementL; self.cylinders = cylinders
        self.aspiration = aspiration; self.drive = drive; self.transmission = transmission; self.hp = hp
        self.torqueLbFt = torqueLbFt; self.weightLb = weightLb; self.redline = redline; self.gears = gears
        self.specSource = specSource
    }
    /// "2019 Ford Mustang GT".
    public var label: String { [String(year), make, model, trim].compactMap { $0 }.joined(separator: " ") }
}

/// Partial result of a VIN decode; the picker lands on the first unresolved step.
public struct VINDecode: Hashable, Sendable {
    public var year: Int?
    public var make: String?
    public var model: String?
    public var trim: String?
    public var variantID: Int64?
    public init(year: Int? = nil, make: String? = nil, model: String? = nil, trim: String? = nil, variantID: Int64? = nil) {
        self.year = year; self.make = make; self.model = model; self.trim = trim; self.variantID = variantID
    }
}
