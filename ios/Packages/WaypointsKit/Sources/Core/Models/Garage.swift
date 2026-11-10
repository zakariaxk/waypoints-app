import Foundation

// Section 5.2

public enum Clearance: String, Sendable, Codable, Hashable, CaseIterable { case stock, lowered, slammed }

public enum Drivetrain: String, Sendable, Codable, Hashable, CaseIterable { case fwd, rwd, awd, fourWD = "4wd" }

/// `cars.spec_overrides`: user corrections to catalog specs.
public struct SpecOverrides: Hashable, Sendable, Codable {
    public var hp: Int?
    public var torqueLbFt: Int?
    public var weightLb: Int?
    public var drivetrain: Drivetrain?
    public var redline: Int?
    public var gears: [Double]?
    public init(hp: Int? = nil, torqueLbFt: Int? = nil, weightLb: Int? = nil, drivetrain: Drivetrain? = nil,
                redline: Int? = nil, gears: [Double]? = nil) {
        self.hp = hp; self.torqueLbFt = torqueLbFt; self.weightLb = weightLb
        self.drivetrain = drivetrain; self.redline = redline; self.gears = gears
    }
    public var isEmpty: Bool { self == SpecOverrides() }
}

public struct Car: Identifiable, Hashable, Sendable, Codable {
    public let id: CarID
    public let ownerID: UserID
    public var catalogVariantID: Int64?
    public var year: Int
    public var make: String
    public var model: String
    public var trim: String?
    public var nickname: String?
    public var colorFamily: String?
    public var colorHex: String?              // "#RRGGBB"
    public var paintName: String?
    public var clearance: Clearance
    public var specOverrides: SpecOverrides
    public var mods: [String]                 // mod ids from tools/mods
    public var sort: Int
    public var createdAt: Date

    public init(
        id: CarID = CarID(), ownerID: UserID, catalogVariantID: Int64? = nil, year: Int, make: String, model: String,
        trim: String? = nil, nickname: String? = nil, colorFamily: String? = nil, colorHex: String? = nil,
        paintName: String? = nil, clearance: Clearance = .stock, specOverrides: SpecOverrides = .init(),
        mods: [String] = [], sort: Int = 0, createdAt: Date = .now
    ) {
        self.id = id; self.ownerID = ownerID; self.catalogVariantID = catalogVariantID; self.year = year
        self.make = make; self.model = model; self.trim = trim; self.nickname = nickname
        self.colorFamily = colorFamily; self.colorHex = colorHex; self.paintName = paintName
        self.clearance = clearance; self.specOverrides = specOverrides; self.mods = mods
        self.sort = sort; self.createdAt = createdAt
    }

    /// "2019 Mustang GT", the `CarBadge` form.
    public var shortLabel: String { [String(year), model, trim].compactMap { $0 }.joined(separator: " ") }
    /// "2019 Ford Mustang GT".
    public var fullLabel: String { [String(year), make, model, trim].compactMap { $0 }.joined(separator: " ") }
}

/// What a client supplies to create a car; the server assigns id and owner.
public struct NewCar: Hashable, Sendable, Codable {
    public var catalogVariantID: Int64?
    public var year: Int
    public var make: String
    public var model: String
    public var trim: String?
    public var nickname: String?
    public var colorFamily: String?
    public var colorHex: String?
    public var paintName: String?
    public var clearance: Clearance
    public init(catalogVariantID: Int64? = nil, year: Int, make: String, model: String, trim: String? = nil,
                nickname: String? = nil, colorFamily: String? = nil, colorHex: String? = nil,
                paintName: String? = nil, clearance: Clearance = .stock) {
        self.catalogVariantID = catalogVariantID; self.year = year; self.make = make; self.model = model
        self.trim = trim; self.nickname = nickname; self.colorFamily = colorFamily; self.colorHex = colorHex
        self.paintName = paintName; self.clearance = clearance
    }
}

public struct CarPhoto: Identifiable, Hashable, Sendable, Codable {
    public let id: CarPhotoID
    public let carID: CarID
    public var path: String
    public var width: Int
    public var height: Int
    public var sort: Int
    public init(id: CarPhotoID = CarPhotoID(), carID: CarID, path: String, width: Int, height: Int, sort: Int = 0) {
        self.id = id; self.carID = carID; self.path = path; self.width = width; self.height = height; self.sort = sort
    }
}

public struct BuildEntry: Identifiable, Hashable, Sendable, Codable {
    public let id: BuildEntryID
    public let carID: CarID
    public var happenedOn: Date
    public var title: String                  // ≤60
    public var body: String                   // ≤500
    public var photoPath: String?
    public var modID: String?
    public var createdAt: Date
    public init(id: BuildEntryID = BuildEntryID(), carID: CarID, happenedOn: Date, title: String, body: String = "",
                photoPath: String? = nil, modID: String? = nil, createdAt: Date = .now) {
        self.id = id; self.carID = carID; self.happenedOn = happenedOn; self.title = title; self.body = body
        self.photoPath = photoPath; self.modID = modID; self.createdAt = createdAt
    }
}
