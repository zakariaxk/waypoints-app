import Core
import Foundation

/// JSON over HTTPS with the Supabase access token as a bearer token. Keys are snake_case and
/// dates are RFC 3339, matching Go's `encoding/json` defaults for `time.Time`.
struct GatewayClient: Sendable {
    let baseURL: URL
    let auth: any AuthService
    let session: URLSession

    init(baseURL: URL, auth: any AuthService, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL; self.auth = auth; self.session = session
    }

    struct Empty: Codable, Sendable {}

    @discardableResult
    func send(_ method: String, _ path: String) async throws -> Empty {
        try await send(method, path, body: Empty?.none, as: Empty.self)
    }

    @discardableResult
    func send<Body: Encodable & Sendable>(_ method: String, _ path: String, body: Body) async throws -> Empty {
        try await send(method, path, body: body, as: Empty.self)
    }

    func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ method: String, _ path: String, body: Body?, as: Response.Type
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut,
                 .cannotFindHost, .dataNotAllowed:
                throw WaypointsError.offline
            default:
                throw WaypointsError.server(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw WaypointsError.server("no response") }
        guard (200..<300).contains(http.statusCode) else { throw Self.error(status: http.statusCode, data: data) }

        if Response.self == Empty.self, let empty = Empty() as? Response { return empty }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw WaypointsError.server("decode \(Response.self): \(error)")
        }
    }

    private struct ErrorBody: Decodable { var error: String?; var message: String? }

    static func error(status: Int, data: Data) -> WaypointsError {
        let body = try? decoder.decode(ErrorBody.self, from: data)
        let message = body?.message ?? body?.error ?? String(decoding: data.prefix(200), as: UTF8.self)
        switch status {
        case 401: return .notSignedIn
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict(message)
        case 400, 422: return .invalid(message)
        case 429: return .rateLimited
        default: return .server("\(status) \(message)")
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }()

    /// Go writes `time.Time` as RFC 3339 with up to nine fractional digits and a numeric offset.
    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        let whole = string.replacing(/\.\d+/, with: "", maxReplacements: 1)
        return try? Date.ISO8601FormatStyle().parse(whole)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not RFC 3339: \(string)")
            }
            return date
        }
        return decoder
    }()
}
