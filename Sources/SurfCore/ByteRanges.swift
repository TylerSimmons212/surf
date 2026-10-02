import Foundation

/// Splitting one file into pieces that can be fetched at the same time.
///
/// A segmented stream arrives already divided, and the whole engine is built
/// around that. A plain file does not, which is why it has always gone to WebKit
/// and been fetched on a single connection — and a single connection is the
/// slowest way to move a large file. Measured against one CDN, the same bytes
/// took 59 seconds in sequence and 10 in parallel.
///
/// Ranges make a plain file look like a segmented one. Everything downstream then
/// treats it as such: the same schedule, the same in-order append, the same
/// adaptive connection count.
public enum ByteRanges {

    /// Below this, splitting costs more than it saves.
    ///
    /// Every piece is a request, and at 256KB the per-request overhead is a
    /// measurable fraction of the transfer while at a megabyte it is a few per
    /// cent. So pieces are at least this big even when that means fewer of them
    /// than asked for.
    public static let minimumChunk = 1 << 20

    /// Below this, a file is not worth splitting at all.
    ///
    /// Eight megabytes is roughly where the parallel win exceeds the cost of the
    /// extra round trips on an ordinary connection. Under it, the existing path
    /// through WebKit is both simpler and no slower, and changing the most common
    /// download in the browser for no gain is not a trade worth making.
    public static let worthSplitting = 8 << 20

    /// Contiguous pieces covering `0..<length`, in order.
    ///
    /// Empty when the length is unusable, which the caller must read as "fetch it
    /// the ordinary way" rather than "fetch nothing".
    public static func chunks(of length: Int, into count: Int) -> [Range<Int>] {
        guard length > 0, count > 0 else { return [] }

        // Honour the minimum over the requested count. Asking for eight pieces of
        // a two-megabyte file gets two, because the alternative is six requests
        // whose overhead exceeds what they carry.
        let usable = min(count, max(1, length / minimumChunk))
        let size = length / usable
        guard size > 0 else { return [0..<length] }

        var ranges: [Range<Int>] = []
        var start = 0
        for index in 0..<usable {
            // The last piece takes the remainder, so integer division cannot
            // leave the end of the file unfetched. Getting this wrong produces a
            // file a few bytes short, which plays and is wrong.
            let end = index == usable - 1 ? length : start + size
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Whether a response says this file can be fetched in pieces.
    ///
    /// Both halves matter. `Accept-Ranges: bytes` is the server's promise, and a
    /// length is needed to divide. A server that omits the header may still
    /// honour a range, but guessing wrong means a request that returns the whole
    /// file where a piece was expected — which `SegmentFetcher` refuses, correctly
    /// and after transferring all of it.
    public static func areSupported(acceptRanges: String?, contentLength: Int?) -> Bool {
        guard let contentLength, contentLength > 0 else { return false }
        guard let acceptRanges = acceptRanges?.lowercased() else { return false }
        return acceptRanges.contains("bytes")
    }

    /// Whether splitting this file is worth the extra requests.
    public static func worthSplitting(
        length: Int?, acceptRanges: String?
    ) -> Bool {
        guard let length, length >= worthSplitting else { return false }
        return areSupported(acceptRanges: acceptRanges, contentLength: length)
    }
}
