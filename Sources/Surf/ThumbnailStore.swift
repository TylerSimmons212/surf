import AppKit
import ImageIO
import SwiftUI

/// Result thumbnails, fetched once and decoded once.
///
/// `AsyncImage` has no cache. Scrolling a grid past a card and back re-fetches
/// the picture and re-decodes it, and a full-size JPEG decode happens on the
/// main thread at draw time — seventeen of those per scroll is what a
/// stuttering grid is made of.
///
/// So: one fetch per address, and ImageIO's thumbnail path rather than
/// `NSImage(data:)`, because it decodes *straight to* the size being drawn
/// instead of decoding full-size and shrinking afterwards. The decode is
/// forced while still off the main actor, so nothing is left for the draw to
/// do.
///
/// Memory only. A thumbnail is not worth a file on disk, and Surf keeps as
/// little as it can anyway.
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    private let cache = NSCache<NSURL, NSImage>()
    /// One fetch per address even when six cards ask at once — a grid
    /// scrolled quickly asks for the same picture repeatedly.
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        cache.countLimit = 240
    }

    /// The picture if it is already here — checked synchronously by the view
    /// so a card that has been seen before draws without a frame of grey.
    func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL, maxPixel: CGFloat) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }

        let task = Task<NSImage?, Never> {
            await Self.load(url, maxPixel: maxPixel)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Plain and cookieless, deliberately: this is a public image host, the
    /// request needs no identity, and `URLSession` carries none of the web
    /// view's session into it.
    private nonisolated static func load(
        _ url: URL, maxPixel: CGFloat
    ) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url)
        else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return nil
        }
        return downsample(data, maxPixel: maxPixel)
    }

    private nonisolated static func downsample(
        _ data: Data, maxPixel: CGFloat
    ) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // The whole point: decode now, here, off the main actor — rather
            // than lazily, on the main thread, during a scroll.
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else { return nil }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }
}

/// A cached, pre-decoded thumbnail.
struct ThumbnailImage: View {
    let address: String
    /// The longest edge to decode to, in pixels.
    var maxPixel: CGFloat = 720

    /// What this view fetched, and for which address — the pair, because a
    /// recycled card keeps the `@State` of the card it replaced and would
    /// otherwise draw the previous result's picture for a frame.
    @State private var loaded: (address: String, image: NSImage)?

    private var url: URL? { URL(string: address) }

    /// The cache is read in the body, not only in `.task`.
    ///
    /// `.task` runs after the first render, so a card scrolling back into
    /// view drew a frame of grey and then popped its picture in — even
    /// though the picture was already in memory. One frame per card per
    /// recycle is most of what a grid that "isn't smooth" actually is.
    private var image: NSImage? {
        if let loaded, loaded.address == address { return loaded.image }
        return url.flatMap { ThumbnailStore.shared.cached($0) }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        // Keyed on the address: a recycled card asks for its new picture, and
        // one whose picture is already cached never enters the task body at
        // all, because `image` above already answered.
        .task(id: address) {
            guard let url, ThumbnailStore.shared.cached(url) == nil else { return }
            let image = await ThumbnailStore.shared.image(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled, let image else { return }
            loaded = (address, image)
        }
    }
}
