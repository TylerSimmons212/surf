import Foundation

/// How far a stream download got, so a retry can carry on instead of starting
/// over.
///
/// A sidecar file, and this one is genuinely necessary rather than a second copy
/// of something already on disk. The earlier design assumed each segment would be
/// its own file, which makes the directory listing the record: a file that is
/// present is a segment that is done. The output here is one file appended to in
/// order, which is cheaper in disk and in peak space and means a listing cannot
/// say how many segments are inside it. Something has to.
///
/// What it has to hold is not just a count. A manifest can change between the
/// failure and the retry — a live edge moves, a publisher re-encodes, a signed
/// URL resolves to a different rendition — and resuming into a file whose
/// contents no longer line up with the plan produces exactly the kind of corrupt
/// output that plays. So the record describes the work as well as the progress,
/// and a mismatch starts over rather than guessing.
public struct StreamProgress: Equatable, Sendable {

    /// Which rendition the bytes on disk belong to.
    public var renditionID: String

    /// How many segments that rendition had when the plan was made.
    public var segmentCount: Int

    /// How many of them are in the file, from the start, contiguously.
    public var done: Int

    /// Where the file ends. Carried separately rather than derived, because the
    /// file on disk may be longer than this: a write interrupted partway leaves
    /// a tail that was never accounted for, and resuming from the file's own
    /// length would splice a partial segment into the middle of the video.
    public var bytes: Int

    public init(renditionID: String, segmentCount: Int, done: Int, bytes: Int) {
        self.renditionID = renditionID
        self.segmentCount = segmentCount
        self.done = done
        self.bytes = bytes
    }

    /// Bumped if the shape ever changes, so an old sidecar is discarded rather
    /// than misread. There is no migration story here and there should not be:
    /// the cost of not understanding one is re-downloading a file.
    static let version = 1

    /// One key per line, which is enough structure for four numbers and a string
    /// and avoids pulling a serialiser in for them.
    public var text: String {
        """
        surf-stream \(Self.version)
        rendition \(renditionID)
        segments \(segmentCount)
        done \(done)
        bytes \(bytes)
        """
    }

    /// Nil for anything unreadable, which the caller must treat as "start over".
    ///
    /// Strict on purpose. Every field is required and every number must parse,
    /// because a half-understood record is worse than none: it would resume into
    /// a file using a count it had guessed at.
    public static func parse(_ text: String) -> StreamProgress? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        guard fields["surf-stream"].flatMap(Int.init) == version,
              let rendition = fields["rendition"], !rendition.isEmpty,
              let segments = fields["segments"].flatMap(Int.init),
              let done = fields["done"].flatMap(Int.init),
              let bytes = fields["bytes"].flatMap(Int.init)
        else { return nil }

        // Nonsense that parsed. A negative count, more done than exist, or
        // progress claiming segments with no bytes behind them.
        guard segments > 0, done >= 0, done <= segments, bytes >= 0 else { return nil }
        guard done == 0 || bytes > 0 else { return nil }

        return StreamProgress(
            renditionID: rendition, segmentCount: segments, done: done, bytes: bytes
        )
    }

    /// Whether this records progress on the work about to be done.
    ///
    /// Both halves matter. A different rendition means different bytes at every
    /// offset. A different segment count means the manifest changed underneath
    /// us, and even if the rendition name is the same the boundaries may not be.
    public func describes(renditionID: String, segmentCount: Int) -> Bool {
        self.renditionID == renditionID && self.segmentCount == segmentCount
    }

    /// Nothing to resume. Distinct from a mismatch: this is a record that is
    /// honest and says no progress was made, which is still worth believing
    /// rather than re-deriving.
    public var isEmpty: Bool { done == 0 }
}
