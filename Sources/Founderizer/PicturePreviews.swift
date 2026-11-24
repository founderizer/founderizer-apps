import AppKit
import FleetCore
import SwiftUI

/// Each view uses its own task. The actor completes one decode at a time, so the next
/// view of the same picture takes its result. An offscreen view skips work still in line.
actor PicturePreviews {
    struct Key: Hashable, Sendable {
        let file: String
        let pixels: Int
        var name: NSString { "\(pixels)/\(file)" as NSString }
    }

    /// NSCache supports concurrent reads and writes. A view can draw a hit in its first frame.
    private final class Images: @unchecked Sendable {
        let cache = NSCache<NSString, CGImage>()
        init() { cache.totalCostLimit = 32 * 1024 * 1024 }
    }

    private nonisolated let images = Images()

    nonisolated func cached(_ key: Key) -> CGImage? { images.cache.object(forKey: key.name) }

    func image(_ key: Key, bytes: @Sendable () -> Data?) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cached(key) { return image }
        guard let data = bytes(), !Task.isCancelled,
              let image = MessageAttachment.thumbnail(data, maxPixels: key.pixels, decodeImmediately: true) else { return nil }
        images.cache.setObject(image, forKey: key.name, cost: image.bytesPerRow * image.height)
        return image
    }
}

/// A tile can change files while the preceding decode is still running.
struct CachedThumbnail<Content: View>: View {
    let previews: PicturePreviews
    let key: PicturePreviews.Key
    var available = true
    let bytes: @Sendable () -> Data?
    @ViewBuilder var content: (CGImage?, Bool) -> Content

    private struct Input: Equatable {
        let key: PicturePreviews.Key
        let available: Bool
    }
    @State private var loadedKey: PicturePreviews.Key?
    @State private var loadedImage: CGImage?

    var body: some View {
        let image = previews.cached(key) ?? (key == loadedKey ? loadedImage : nil)
        content(image, key == loadedKey)
            .task(id: Input(key: key, available: available)) {
                if let image {
                    loadedImage = image
                    loadedKey = key
                    return
                }
                guard available else { return }
                let image = await previews.image(key, bytes: bytes)
                guard !Task.isCancelled else { return }
                loadedImage = image
                loadedKey = key
            }
    }
}
