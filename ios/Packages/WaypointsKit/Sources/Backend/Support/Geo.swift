import Core
import Foundation

/// PostGIS values as PostgREST moves them. Writes send EWKT text, which Postgres casts to
/// `geography`. Reads of a raw `geography` column return hex EWKB; the RPCs return plain
/// latitude and longitude, or GeoJSON for lines.
enum Geo {
    static func ewkt(_ c: Coordinate) -> String {
        "SRID=4326;POINT(\(c.longitude) \(c.latitude))"
    }

    static func ewkt(_ path: [Coordinate]) -> String {
        "SRID=4326;LINESTRING(" + path.map { "\($0.longitude) \($0.latitude)" }.joined(separator: ",") + ")"
    }

    /// First coordinate of a hex EWKB point (or any geometry with a leading point list).
    static func point(fromEWKB hex: String) -> Coordinate? {
        coordinates(fromEWKB: hex)?.first
    }

    /// Decodes a hex EWKB `POINT` or `LINESTRING`, with or without an SRID.
    static func coordinates(fromEWKB hex: String) -> [Coordinate]? {
        guard let bytes = bytes(fromHex: hex), bytes.count >= 5 else { return nil }
        var reader = Reader(bytes: bytes, littleEndian: bytes[0] == 1)
        reader.offset = 1
        guard let rawType = reader.uint32() else { return nil }
        if rawType & 0x2000_0000 != 0 { _ = reader.uint32() }          // SRID
        let hasZ = rawType & 0x8000_0000 != 0
        let hasM = rawType & 0x4000_0000 != 0
        let extra = (hasZ ? 1 : 0) + (hasM ? 1 : 0)
        func readPoint() -> Coordinate? {
            guard let x = reader.double(), let y = reader.double() else { return nil }
            for _ in 0..<extra { _ = reader.double() }
            return Coordinate(latitude: y, longitude: x)
        }
        switch rawType & 0xFFFF {
        case 1:
            return readPoint().map { [$0] }
        case 2:
            guard let n = reader.uint32(), n < 100_000 else { return nil }
            var out: [Coordinate] = []
            out.reserveCapacity(Int(n))
            for _ in 0..<n {
                guard let p = readPoint() else { return nil }
                out.append(p)
            }
            return out
        default:
            return nil
        }
    }

    /// `{"type":"LineString","coordinates":[[lng,lat],...]}` from `st_asgeojson`.
    static func coordinates(fromGeoJSON json: String) -> [Coordinate] {
        struct Line: Decodable { let coordinates: [[Double]] }
        guard let data = json.data(using: .utf8),
              let line = try? JSONDecoder().decode(Line.self, from: data) else { return [] }
        return line.coordinates.compactMap { $0.count >= 2 ? Coordinate(latitude: $0[1], longitude: $0[0]) : nil }
    }

    static func length(of path: [Coordinate]) -> Int {
        Int(zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) })
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let s = hex.hasPrefix("\\x") ? hex.dropFirst(2) : Substring(hex)
        guard s.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    private struct Reader {
        let bytes: [UInt8]
        let littleEndian: Bool
        var offset = 0

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for i in 0..<4 {
                let b = UInt32(bytes[offset + (littleEndian ? i : 3 - i)])
                v |= b << (8 * UInt32(i))
            }
            offset += 4
            return v
        }

        mutating func double() -> Double? {
            guard offset + 8 <= bytes.count else { return nil }
            var v: UInt64 = 0
            for i in 0..<8 {
                let b = UInt64(bytes[offset + (littleEndian ? i : 7 - i)])
                v |= b << (8 * UInt64(i))
            }
            offset += 8
            return Double(bitPattern: v)
        }
    }
}

/// `bytea` as PostgREST reads and writes it: "\x" followed by hex.
enum Bytea {
    static func encode(_ data: Data) -> String {
        "\\x" + data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ string: String?) -> Data {
        guard let string, string.hasPrefix("\\x") else { return Data() }
        let hex = string.dropFirst(2)
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            if let byte = UInt8(hex[index..<next], radix: 16) { data.append(byte) }
            index = next
        }
        return data
    }
}
