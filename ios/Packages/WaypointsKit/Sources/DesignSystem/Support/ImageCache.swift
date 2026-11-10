import SwiftUI
import UIKit

/// The in-memory image cache plan 4.4 allows instead of an image-loading library. Decoded
/// images are kept per URL up to `limit`, oldest dropped first; bytes also pass through the
/// shared `URLCache`, so a relaunch revalidates rather than refetching.
public actor ImageCache {
    public static let shared = ImageCache()

    private var images: [URL: UIImage] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let limit = 200

    public func image(for url: URL) async -> UIImage? {
        if let hit = images[url] { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return UIImage(data: data)?.preparingForDisplay()
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { insert(image, for: url) }
        return image
    }

    private func insert(_ image: UIImage, for url: URL) {
        images[url] = image
        order.append(url)
        if order.count > limit { images[order.removeFirst()] = nil }
    }
}

/// `AsyncImage` with the shared cache. Shows `placeholder` until the image is ready.
public struct CachedImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    @State private var image: UIImage?

    public init(url: URL?, @ViewBuilder content: @escaping (Image) -> Content, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            if let image { content(Image(uiImage: image)) } else { placeholder() }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let loaded = await ImageCache.shared.image(for: url)
            withAnimation(.easeInOut(duration: Timing.crossfade)) { image = loaded }
        }
    }
}
