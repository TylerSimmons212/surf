import Foundation

/// Reads a manifest without the caller knowing which kind it is.
///
/// The one entry point everything outside `SurfCore` uses, and the reason adding
/// a third format will not touch the app at all. The runner used to call
/// `HLSPlaylist.parse` by name, which meant that supporting DASH — a change
/// entirely describable as "one more parser" — needed an edit in
/// `Sources/Surf` anyway. That was the whole claim the boundary was supposed to
/// make, and naming a parser at the call site was quietly breaking it.
///
/// The order is cheapest first. An m3u8 is recognised by its first line, so the
/// HLS parser declines a non-playlist immediately; the DASH parser has to build
/// an XML document before it can say anything.
public enum StreamManifest {

    /// Nil when this is neither format, or is one we cannot read.
    ///
    /// Both parsers decline what the other handles — there is a test for it in
    /// both directions — so trying them in sequence cannot produce a confident
    /// wrong answer, only a nil.
    public static func parse(_ text: String, baseURL: URL) -> StreamIndex? {
        HLSPlaylist.parse(text, baseURL: baseURL)
            ?? DASHManifest.parse(text, baseURL: baseURL)
    }
}
