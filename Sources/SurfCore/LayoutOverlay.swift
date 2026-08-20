import Foundation

/// What the agent reports about one grid or flex container, in CSS pixels
/// relative to the viewport.
///
/// Raw material, not drawing instructions: track spans and item rects come
/// from the page, and `LayoutOverlayGeometry` below turns them into lines,
/// numbers and gap rects. The split exists so the part that can be wrong in
/// interesting ways — where line 2 sits when there's a gap, which rect is a
/// gap at all — is pure logic with tests, and the view only strokes paths.
public struct LayoutOverlay: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case grid, flex
    }

    /// One track's extent along its axis.
    public struct Span: Sendable, Equatable {
        public var start: Double
        public var end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public var kind: Kind
    public var nodeId: DOMNodeID
    /// The container's border box.
    public var bounds: CGRect
    /// Column and row tracks — grid only.
    public var columns: [Span]
    public var rows: [Span]
    /// Item border boxes — flex only.
    public var items: [CGRect]

    public init(
        kind: Kind,
        nodeId: DOMNodeID,
        bounds: CGRect,
        columns: [Span] = [],
        rows: [Span] = [],
        items: [CGRect] = []
    ) {
        self.kind = kind
        self.nodeId = nodeId
        self.bounds = bounds
        self.columns = columns
        self.rows = rows
        self.items = items
    }
}

/// Lines, numbers and gaps, computed from track spans.
public enum LayoutOverlayGeometry {

    /// One grid line: where to draw it, and what to call it.
    public struct Line: Sendable, Equatable {
        public var position: Double
        /// 1-based, as CSS numbers them. (Negative aliases exist in CSS but
        /// drawing both spellings on one line is clutter, not information.)
        public var number: Int

        public init(position: Double, number: Int) {
            self.position = position
            self.number = number
        }
    }

    /// Grid lines for one axis. `n` tracks produce `n + 1` lines: the first
    /// sits at the first track's start, the last at the last track's end, and
    /// each line between two tracks sits in the *middle* of the gap — which
    /// is where CSS itself considers the line to be, the gap being the line's
    /// thickness made visible.
    public static func lines(for tracks: [LayoutOverlay.Span]) -> [Line] {
        guard let first = tracks.first, let last = tracks.last else { return [] }
        var out = [Line(position: first.start, number: 1)]
        for index in 1..<tracks.count {
            let position = (tracks[index - 1].end + tracks[index].start) / 2
            out.append(Line(position: position, number: index + 1))
        }
        out.append(Line(position: last.end, number: tracks.count + 1))
        return out
    }

    /// The spaces between consecutive tracks — the gaps worth shading.
    /// Zero-width gaps are dropped: hatching a 0px gap draws a smear on top
    /// of a line.
    public static func gaps(in tracks: [LayoutOverlay.Span]) -> [LayoutOverlay.Span] {
        guard tracks.count > 1 else { return [] }
        return (1..<tracks.count).compactMap { index in
            let gap = LayoutOverlay.Span(
                start: tracks[index - 1].end, end: tracks[index].start
            )
            return gap.end - gap.start > 0.5 ? gap : nil
        }
    }
}
