import Foundation

/// A `PropertyTrace` arranged as a staircase: the winner, then each loser
/// stepping one level right in the order it lost.
///
/// Depth is the whole idea. A flat list of struck-through rows makes you read
/// every reason before you know the shape of the fight; a staircase says
/// "four rules tried, this one won, the rest fell away in this order" before a
/// single word is read. Rank is the one thing about a cascade you should not
/// have to read.
///
/// The reason this is a value type in the core rather than a `ForEach` with an
/// index-times-indent is the cap. A staircase is only legible while it fits:
/// `font-size` on a heading in a real stylesheet can be set a dozen times, and
/// twelve levels of indent walks off the right edge of the pane and takes the
/// reasons with it. Where that cap falls, and what happens to the entries past
/// it, is a decision with edge cases — so it is written once, here, and tested.
public struct CascadeStack: Sendable, Equatable {

    /// One visible line of the staircase.
    public struct Step: Sendable, Equatable, Identifiable {
        public var entry: TraceEntry
        /// Levels right of the winner. The winner is 0.
        public var depth: Int

        public var id: String { entry.id }
        public var isWinner: Bool { depth == 0 }

        public init(entry: TraceEntry, depth: Int) {
            self.entry = entry
            self.depth = depth
        }
    }

    /// Winner first, then the losers that fit.
    public var steps: [Step]
    /// Losers folded away past the cap, in the order they lost. Empty unless
    /// folding actually bought something.
    public var hidden: [TraceEntry]

    /// How far the staircase is allowed to step.
    ///
    /// Four is where indentation stops carrying rank: by the fifth level the
    /// eye is measuring whitespace rather than counting steps, and at
    /// `DevToolsTheme.indent` the reasons have lost most of a narrow pane's
    /// width to the margin.
    public static let maxDepth = 4

    public init(_ trace: PropertyTrace) {
        let entries = trace.entries
        guard let winner = entries.first else {
            self.steps = []
            self.hidden = []
            return
        }

        let losers = Array(entries.dropFirst())
        var steps = [Step(entry: winner, depth: 0)]

        // Fold as soon as the staircase would outrun the cap, even when that
        // hides only one row.
        //
        // The tempting alternative — never fold a single entry, since the
        // summary line costs the same height as the row it replaces — was
        // wrong. Showing a fifth loser means saturating its depth to the
        // fourth, which puts two cards at the same indent, and equal indent in
        // a staircase reads as equal rank. These two did not tie; one beat the
        // other. A fold line that occasionally hides one row is a small cost.
        // A staircase that quietly claims a tie is the exact failure this pane
        // exists to prevent.
        for (rank, entry) in losers.prefix(Self.maxDepth).enumerated() {
            steps.append(Step(entry: entry, depth: rank + 1))
        }
        self.steps = steps
        self.hidden = losers.count > Self.maxDepth
            ? Array(losers.dropFirst(Self.maxDepth))
            : []
    }

    /// What the fold line says.
    ///
    /// Names the shared reason when there is one, because "6 more, all lost on
    /// specificity" is an answer and "6 more" is a chore. When the hidden
    /// entries lost in different ways it says only the count — claiming a
    /// single reason for a mixed group would be the one thing this pane exists
    /// not to do.
    public var hiddenSummary: String? {
        guard !hidden.isEmpty else { return nil }
        let count = "\(hidden.count) more"
        let phrases = Set(hidden.map(\.outcome.lossPhrase))
        guard phrases.count == 1, let phrase = phrases.first, let phrase else { return count }
        // "1 more, all lost on specificity" is not English.
        let verb = hidden.count == 1 ? "which lost" : "all lost"
        return "\(count), \(verb) \(phrase)"
    }
}

extension CascadeOutcome {
    /// How this declaration lost, as a phrase that completes "lost …".
    ///
    /// Deliberately drops the particulars the full explanation carries — the
    /// actual specificity numbers, which layer beat which — so that a run of
    /// losers can be summarised without implying they all lost by the same
    /// margin. `nil` for the winner, which did not lose.
    public var lossPhrase: String? {
        switch self {
        case .winner: nil
        case .lostToNearerElement: "to the element's own declaration"
        case .lostToImportant: "to an !important"
        case .lostToOrigin: "to a higher-priority origin"
        case .lostToStyleAttribute: "to the style attribute"
        case .lostToLayer: "to a later cascade layer"
        case .lostToSpecificity: "on specificity"
        case .lostToOrder: "on order"
        case .shadowedInSameRule: "to a later line in the same rule"
        }
    }
}
