import Core
import Foundation
import ImageIO
import Supabase
import UniformTypeIdentifiers

/// Supabase Storage. Uploads go through `URLSession` directly so progress can be reported
/// (the SDK's upload has no progress callback). Images are re-encoded as JPEG with the long
/// edge capped at 2048 px, which also drops EXIF, including any GPS position.
struct LiveMedia: MediaStore {
    let ctx: BackendContext
    static let maxPixels = 2048

    func upload(_ data: Data, contentType: String, to bucket: MediaBucket,
                progress: @escaping @Sendable (Double) -> Void) async throws -> StoredMedia {
        let me = try ctx.me()
        guard bucket != .catalog else { throw WaypointsError.forbidden }
        var body = data
        var type = contentType
        var width: Int?
        var height: Int?
        if contentType.hasPrefix("image/") {
            guard let image = Self.downscaledJPEG(data) else { throw WaypointsError.invalid("image") }
            body = image.data; type = "image/jpeg"; width = image.width; height = image.height
        }
        let ext = UTType(mimeType: type)?.preferredFilenameExtension ?? "bin"
        let path = "\(me.key)/\(UUID().uuidString.lowercased()).\(ext)"

        let token = try await ctx.run { try await ctx.client.auth.session.accessToken }
        var request = URLRequest(url: ctx.config.supabaseURL
            .appending(path: "storage/v1/object/\(bucket.rawValue)/\(path)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(ctx.config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=31536000", forHTTPHeaderField: "Cache-Control")
        request.setValue("false", forHTTPHeaderField: "x-upsert")

        progress(0)
        let (responseBody, response) = try await ctx.run {
            try await URLSession.shared.upload(for: request, from: body, delegate: UploadProgress(progress))
        }
        guard let http = response as? HTTPURLResponse else { throw WaypointsError.server("No response") }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw WaypointsError.notSignedIn
        case 403: throw WaypointsError.forbidden
        case 409: throw WaypointsError.conflict("path")
        case 413: throw WaypointsError.invalid("size")
        case 429: throw WaypointsError.rateLimited
        default: throw WaypointsError.server(String(decoding: responseBody, as: UTF8.self))
        }
        progress(1)
        return StoredMedia(bucket: bucket, path: path, width: width, height: height)
    }

    func delete(_ media: StoredMedia) async throws {
        _ = try await ctx.run { try await ctx.client.storage.from(media.bucket.rawValue).remove(paths: [media.path]) }
    }

    func publicURL(bucket: MediaBucket, path: String) -> URL {
        ctx.config.supabaseURL.appending(path: "storage/v1/object/public/\(bucket.rawValue)/\(path)")
    }

    /// Decodes any ImageIO format (HEIC, JPEG, PNG), applies the EXIF orientation, caps the long
    /// edge, and writes a JPEG with no metadata.
    static func downscaledJPEG(_ data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (out as Data, image.width, image.height)
    }
}

/// Reports upload progress from `URLSession`'s task delegate.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
