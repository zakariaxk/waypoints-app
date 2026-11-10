import Foundation

/// Supabase Storage (implemented by `Backend`). Images are downscaled to 2048 px long edge.
public protocol MediaStore: Sendable {
    /// Uploads under `<user_id>/` in `bucket`. `progress` receives 0...1.
    func upload(_ data: Data, contentType: String, to bucket: MediaBucket,
                progress: @escaping @Sendable (Double) -> Void) async throws -> StoredMedia
    func delete(_ media: StoredMedia) async throws
    func publicURL(bucket: MediaBucket, path: String) -> URL
}
