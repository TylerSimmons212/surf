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
