import Foundation

/// Which segments are being fetched, which are done, and which may start next.
///
/// A cursor, not a worklist, and that one decision is what makes three separate
/// problems go away together.
///
/// A plain worklist with six workers completes segments out of order, which
/// leaves two options: write each to its own file and concatenate afterwards,
/// paying for the whole download twice in disk I/O and twice in peak space, or
/// hold finished segments in memory until their turn comes, with no bound on how
/// many that is. On a 4K stream both of those are expensive.
///
/// Handing out only the indices within a window of the write cursor, and moving
/// that cursor only as segments are written, bounds the buffer at `window`
/// segments, makes the output an in-order append to one file opened once, and
/// makes resuming a matter of seeding what is already done. Same mechanism, three
/// answers.
///
/// Pure and `Equatable`, so the awkward part — what happens when completions
/// arrive in an order nobody planned — is testable without a network.
public struct SegmentSchedule: Equatable, Sendable {

    /// Seconds per segment, which also gives the count.
    ///
    /// Durations rather than a count because progress is weighted by them. A
    /// ten-second segment is worth ten times a one-second one, and counting
    /// segments makes a download of uneven ones report nonsense.
    public let durations: [Double]

    /// How far ahead of the cursor work may be handed out, which is also the most
    /// that can be finished and waiting to be written.
    public let window: Int

    /// How many times one segment may be asked for before the download fails.
    public let attemptLimit: Int

    /// The next index to append to the output file. Everything below it is
    /// already in there.
    public private(set) var cursor: Int

    /// Fetched. Only ever grows, which is what makes `fraction` monotone by
    /// construction rather than by a `max` at the call site.
    private var done: Set<Int>

    private var inFlight: Set<Int> = []
    private var attempts: [Int: Int] = [:]

    /// Segments that ran out of attempts.
    ///
    /// Tracked separately because without it the schedule happily hands a
    /// given-up segment out again, which means `isStalled` can never become true
    /// and a download whose last segment failed waits forever on a completion
    /// that is not coming.
    private var givenUp: Set<Int> = []

    public private(set) var bytesWritten: Int = 0

    /// `completed` seeds a resume, and only its leading run is believed.
    ///
    /// The output is an in-order append, so the file can only contain a
    /// contiguous run from the start. Anything completed after the first gap is
    /// fetched again: cheaper than tracking holes, and the alternative is a file
    /// with one in it.
    ///
    /// The segments on disk are the journal. A separate record of which ones they
    /// are would be a second source of truth about something a directory listing
    /// already states, and the two would disagree the first time a write was
    /// interrupted.
    public init(
        durations: [Double],
        window: Int = 6,
        attemptLimit: Int = 3,
        completed: Set<Int> = []
    ) {
        self.durations = durations
        self.window = max(1, window)
        self.attemptLimit = max(1, attemptLimit)

        var resumed = 0
        while resumed < durations.count, completed.contains(resumed) { resumed += 1 }
        self.cursor = resumed
        self.done = Set(0..<resumed)
    }

    public var count: Int { durations.count }

    /// Every segment fetched. The file may still have writes outstanding, which
    /// is what `isDrained` is for.
    public var isComplete: Bool { done.count == durations.count }

    /// Every segment written. The condition the runner actually finishes on.
    public var isDrained: Bool { cursor == durations.count }

    /// The segment that ended the download, when one did.
    public var failedSegment: Int? { givenUp.min() }

    /// Nothing running and nothing left to hand out, with work remaining.
    ///
    /// A stuck schedule rather than a finished one. Without this a download whose
    /// last segment gave up would wait on a completion that is never coming.
    public var isStalled: Bool {
        !isComplete && inFlight.isEmpty && peekNext() == nil
    }

    /// Duration-weighted and monotone.
    ///
    /// Weighted rather than counted because segments are uneven, and taken from
    /// what has been fetched rather than from bytes because byte totals are not
    /// known until each segment answers. `Content-Length` on a 206 describes one
    /// range, so a byte-based fraction revises downward and reads as a download
    /// going backwards.
    public var fraction: Double {
        guard !durations.isEmpty else { return 1 }
        let total = durations.reduce(0, +)
        // A playlist that declared no durations still has to report something.
        guard total > 0 else { return Double(done.count) / Double(durations.count) }
        return done.reduce(0) { $0 + durations[$1] } / total
    }

    // MARK: - Handing out work

    /// The next segment to fetch, or nil when the window is full, the work is
    /// done, or everything left is already running.
    public mutating func next() -> Int? {
        guard let index = peekNext() else { return nil }
        inFlight.insert(index)
        return index
    }

    private func peekNext() -> Int? {
        guard inFlight.count < window else { return nil }
        // Only within a window of the cursor. This is the bound on how many
        // finished segments can be waiting for their turn, and it is also the
        // backpressure: a caller that stops writing stops fetching.
        let limit = min(durations.count, cursor + window)
        return (cursor..<limit).first {
            !done.contains($0) && !inFlight.contains($0) && !givenUp.contains($0)
        }
    }

    public mutating func complete(_ index: Int, bytes: Int) {
        guard index >= 0, index < durations.count else { return }
        inFlight.remove(index)
        // Guarded so a duplicated completion cannot double-count. Worth doing:
        // the byte total is the one number here that is not idempotent.
        guard !done.contains(index) else { return }
        done.insert(index)
        bytesWritten += max(0, bytes)
    }

    /// Whether that segment is worth asking for again.
    public mutating func fail(_ index: Int) -> Outcome {
        guard index >= 0, index < durations.count else { return .giveUp }
        inFlight.remove(index)
        let attempt = (attempts[index] ?? 0) + 1
        attempts[index] = attempt
        guard attempt < attemptLimit else {
            // Recorded, so it is not offered again and the schedule reads as
            // stalled rather than as work still to do. Left out of `done`, so the
            // file stops at this segment instead of skipping it.
            givenUp.insert(index)
            return .giveUp
        }
        return .retry(attempt: attempt)
    }

    public enum Outcome: Equatable, Sendable {
        case retry(attempt: Int)
        case giveUp
    }

    // MARK: - Writing

    /// The segments that may now be appended, in order, moving the cursor past
    /// them.
    ///
    /// Always contiguous from where the last call left off, which is what lets the
    /// output be one file opened once and appended to with no reassembly pass.
    /// Empty when the next segment in line has not arrived yet, however many
    /// later ones have.
    public mutating func takeWritable() -> [Int] {
        var taken: [Int] = []
        while cursor < durations.count, done.contains(cursor) {
            taken.append(cursor)
            cursor += 1
        }
        return taken
    }
}
