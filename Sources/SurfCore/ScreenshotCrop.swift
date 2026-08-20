import Foundation

/// Turns "the element the user clicked" into "the pixels to keep".
///
/// Three coordinate spaces meet here and each handoff is a classic bug: the
/// element rect arrives in page CSS pixels (top-left origin, scroll
/// included), the snapshot was taken of the page laid out at full height but
/// capped, and the bitmap is in device pixels at some scale. Pure math, so
/// the flips and clamps live under tests instead of under a screenshot that
/// is mysteriously of the wrong place.
public enum ScreenshotCrop {

    /// The pixel rect to cut from a full-page snapshot.
    ///
    /// - Parameters:
    ///   - target: the wanted region in page CSS pixels, top-left origin.
    ///   - capturedHeight: how much page height the snapshot actually shows
    ///     (the full-page cap may have cropped the document).
    ///   - imageSize: the bitmap's size in *pixels*.
    /// - Returns: the crop in pixel coordinates (top-left origin, ready for
    ///   CGImage cropping), or nil when the region lies wholly outside what
    ///   was captured — a click below the cap must fail loudly, not hand
    ///   back a sliver of the wrong content.
    public static func pixelRect(
        for target: CGRect,
        capturedSize: CGSize,
        imageSize: CGSize
    ) -> CGRect? {
        guard capturedSize.width > 0, capturedSize.height > 0 else { return nil }
        guard target.width > 0.5, target.height > 0.5 else { return nil }

        // Clamp to what the snapshot actually contains.
        let visible = CGRect(origin: .zero, size: capturedSize)
            .intersection(target)
        guard !visible.isEmpty, visible.width > 0.5, visible.height > 0.5 else { return nil }

        let scaleX = imageSize.width / capturedSize.width
        let scaleY = imageSize.height / capturedSize.height

        let rect = CGRect(
            x: (visible.minX * scaleX).rounded(.down),
            y: (visible.minY * scaleY).rounded(.down),
            width: (visible.width * scaleX).rounded(.up),
            height: (visible.height * scaleY).rounded(.up)
        )
        // The rounding above can poke one pixel past the edge.
        return rect.intersection(CGRect(origin: .zero, size: imageSize))
    }
}

/// What the page reports while element-pick capture is armed.
public enum CaptureEvent {

    /// The element under the pointer, in viewport CSS pixels.
    public struct Hover: Decodable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    /// The chosen element, with the scroll offsets that turn its viewport
    /// rect into a page rect.
    public struct Pick: Decodable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var scrollX: Double
        public var scrollY: Double

        /// Page coordinates — what the full-page snapshot is addressed in.
        public var pageRect: CGRect {
            CGRect(x: x + scrollX, y: y + scrollY, width: width, height: height)
        }
    }
}
