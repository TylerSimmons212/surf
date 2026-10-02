import Foundation

/// What kind of thing a media element's resolved source actually is.
///
/// This is the routing decision for downloads. A plain file can be fetched by
/// the web view itself; the other two can't, and need an extractor that
/// understands the page rather than the URL.
public enum MediaSourceKind: Sendable, Equatable {
    /// No source yet — the element exists but hasn't resolved anything.
    case none
    /// A plain media file over http(s). Fetchable directly.
    case file
    /// An HLS/DASH index. It's http(s), so it *looks* fetchable, but saving it
    /// gets you a few kilobytes of text pointing at the real segments.
    case manifest
    /// Media Source Extensions: the page assembles segments in its own buffer
    /// and hands the element a `blob:` handle. There is no URL to fetch.
    case streamed
    /// Some other scheme — `data:`, `file:`, an extension's custom scheme.
    case unsupported
}

public enum MediaSource {

    /// Manifest formats we recognise by extension. Deliberately short: these
    /// are the two that matter, and a wrong guess here sends a perfectly
    /// downloadable file down the slow path.
    private static let manifestExtensions: Set<String> = ["m3u8", "m3u", "mpd"]

    /// Media types that mean "this is an index, not the thing it indexes".
    ///
    /// Needed because `kind(of:)` can only guess from the path, and a signed
    /// manifest URL routinely has no extension in it at all. Such a URL
    /// classifies as `.file`, goes down the direct path, and saves a few
    /// kilobytes of playlist text under an `.mp4` name. The response is the
    /// first thing in the whole sequence that can say otherwise.
    private static let manifestTypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "application/mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl",
        "video/vnd.apple.mpegurl",
        "application/dash+xml",
    ]

    /// Whether a response's own declared type says this is a manifest.
    ///
    /// Deliberately not folded into `kind(of:)`: that function answers from a
    /// URL and is called before anything has been requested, while this one
    /// needs a response in hand. Keeping them apart is what stops a caller
    /// believing it can classify a response it does not have.
    ///
    /// `text/plain` is not on the list even though misconfigured servers do
    /// serve playlists as it. Treating it as a manifest would misroute every
    /// genuinely plain file, and a wrong answer here sends a perfectly
    /// downloadable thing to a subprocess that will not find it.
    public static func isManifest(contentType: String) -> Bool {
        // `application/x-mpegURL; charset=utf-8` is one type and one parameter.
        let base = contentType
            .split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return manifestTypes.contains(base)
    }

    public static func kind(of sourceURL: String) -> MediaSourceKind {
        let text = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }

        if text.hasPrefix("blob:") { return .streamed }

        guard text.hasPrefix("http://") || text.hasPrefix("https://") else {
            return .unsupported
        }

        // Query strings routinely carry signing tokens with dots in them, so
        // the extension has to come from the path alone.
        let path = URL(string: text)?.path ?? text
        let ext = (path as NSString).pathExtension.lowercased()
        return manifestExtensions.contains(ext) ? .manifest : .file
    }
}
