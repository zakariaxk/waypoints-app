import Core
import Foundation
import Supabase

/// Shared state for every live repository: one Supabase client and the coders that map
/// snake_case rows onto the camelCase row types in `Rows.swift`.
final class BackendContext: Sendable {
    let client: SupabaseClient
    let config: AppConfig

    init(config: AppConfig) {
        self.config = config
        client = SupabaseClient(
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseAnonKey,
            options: SupabaseClientOptions(
                db: .init(encoder: Coders.encoder(), decoder: Coders.decoder()),
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }

    /// The signed-in user. Throws `notSignedIn` when there is no session.
    func me() throws -> UserID {
        guard let id = client.auth.currentSession?.user.id else { throw WaypointsError.notSignedIn }
        return UserID(raw: id)
    }

    func table(_ name: String) -> PostgrestQueryBuilder { client.from(name) }

    /// Runs a Supabase call and converts its errors into `WaypointsError`.
    func run<T: Sendable>(isolation: isolated (any Actor)? = #isolation,
                          _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> any Error {
        switch error {
        case let error as WaypointsError:
            return error
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                 .cannotFindHost, .dataNotAllowed, .internationalRoamingOff:
                return WaypointsError.offline
            default:
                return WaypointsError.server(error.localizedDescription)
            }
        case let error as PostgrestError:
            switch error.code {
            case "23505": return WaypointsError.conflict(error.message)
            case "23514", "23502", "22001", "22P02", "23503", "22023": return WaypointsError.invalid(error.message)
            case "PT429": return WaypointsError.rateLimited
            case "PT423": return WaypointsError.suspended
            case "42501": return WaypointsError.forbidden
            case "PGRST116", "P0002": return WaypointsError.notFound
            case "PGRST301", "PGRST302": return WaypointsError.notSignedIn
            default: return WaypointsError.server(error.message)
            }
        case let error as AuthError:
            switch error {
            case .sessionMissing:
                return WaypointsError.notSignedIn
            case let .api(message, code, _, response):
                if response.statusCode == 429 || code == .overEmailSendRateLimit || code == .overRequestRateLimit {
                    return WaypointsError.rateLimited
                }
                if code == .otpExpired || code == .validationFailed || response.statusCode == 403 {
                    return WaypointsError.invalid("code")
                }
                return WaypointsError.server(message)
            default:
                return WaypointsError.server(error.localizedDescription)
            }
        case let error as StorageError:
            if error.statusCode == "404" { return WaypointsError.notFound }
            if error.statusCode == "403" { return WaypointsError.forbidden }
            return WaypointsError.server(error.message)
        case is DecodingError:
            return WaypointsError.server("Unexpected response: \(error)")
        default:
            return WaypointsError.server(String(describing: error))
        }
    }
}

/// JSON coders for PostgREST rows: snake_case keys, Postgres timestamps and dates.
enum Coders {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = PostgresDate.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PostgresDate.timestamp(date))
        }
        return encoder
    }
}

enum PostgresDate {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func timestamp(_ date: Date) -> String { date.formatted(fractional) }

    /// `date` columns: the calendar day in the user's time zone, as "yyyy-MM-dd".
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Accepts what PostgREST and Realtime emit: "2026-11-09T18:30:00.123456+00:00", with or
    /// without a fraction or offset, a space instead of "T", "+00" offsets, and bare dates.
    static func parse(_ raw: String) -> Date? {
        if raw.count == 10 {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        var s = raw.replacingOccurrences(of: " ", with: "T")
        // Split off the zone: "Z", or a trailing +HH, +HHMM, +HH:MM after the time part.
        var zone = "Z"
        if s.hasSuffix("Z") {
            s.removeLast()
        } else if let tIndex = s.firstIndex(of: "T"),
                  let signIndex = s[tIndex...].lastIndex(where: { $0 == "+" || $0 == "-" }) {
            var z = String(s[signIndex...])
            s = String(s[..<signIndex])
            if z.count == 3 { z += ":00" }
            if z.count == 5 { z.insert(":", at: z.index(z.startIndex, offsetBy: 3)) }
            zone = z
        }
        // Keep at most millisecond precision.
        if let dot = s.firstIndex(of: ".") {
            let fraction = s[s.index(after: dot)...].prefix(3)
            s = String(s[..<dot]) + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0)
            return try? Date(s + zone, strategy: fractional)
        }
        return try? Date(s + zone, strategy: whole)
    }
}

/// Encodes `nil` as JSON `null`, so an update can clear a column. Synthesized `Encodable`
/// skips `nil` optionals entirely, which PostgREST reads as "leave unchanged".
struct Nullable<Wrapped: Encodable & Sendable>: Encodable, Sendable {
    var value: Wrapped?
    init(_ value: Wrapped?) { self.value = value }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value { try container.encode(value) } else { try container.encodeNil() }
    }
}

/// Text safe to embed in a PostgREST `or=(...)` filter or `ilike` pattern.
func filterSafe(_ text: String) -> String {
    String(text.filter { !",()*%\\:\"'".contains($0) }.prefix(60)).trimmingCharacters(in: .whitespaces)
}

extension UUIDIdentifier {
    /// Lowercase string, the form PostgREST filters and Postgres print.
    var key: String { description }
}
