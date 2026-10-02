import Foundation

/// How many segments to ask for at once, adjusted by what the server does about
/// it.
///
/// A fixed number is wrong in both directions. Four is measurably slower than
/// eight on a fast connection, and eight is how a CDN decides one address is
/// leeching — the answer comes back 429, or worse, silently slower. There is no
/// number that is right for both a home fibre link and a rate-limited edge node,
/// so the number is found rather than chosen.
///
/// The rule is deliberately conservative: climb one connection at a time, keep
/// the climb only when it paid for itself by a clear margin, and give ground much
/// faster than it was taken. Being throttled costs more than being one connection
/// short.
///
/// Pure, so the arithmetic that decides it can be tested without a network — the
/// part that would otherwise only be observable as "downloads got slower for
/// some people".
public struct Parallelism: Equatable, Sendable {

    /// Four, because it is where the published advice and our own measurements
    /// agree: enough to hide latency, not enough to look like abuse.
    public static let start = 4

    /// Eight. Beyond this, every account of parallel downloading reports CDNs
    /// treating the connections as something to limit rather than serve.
    public static let ceiling = 8

    public private(set) var allowed: Int

    private let maximum: Int

    /// What a window of work achieved last time, to compare the next against.
    private var best: Double = 0

    /// Climbing stops for good once a rise failed to pay. A link does not get
    /// faster later in the same download, and probing repeatedly against a server
    /// that said no is how a back-off turns into a sawtooth.
    private var isClimbing = true

    private var samples: [Sample] = []

    private struct Sample: Equatable {
        var bytes: Int
        var seconds: Double
    }

    public init(start: Int = Parallelism.start, maximum: Int = Parallelism.ceiling) {
        self.maximum = max(1, maximum)
        self.allowed = min(max(1, start), self.maximum)
    }

    /// How much a rise has to earn to be kept.
    ///
    /// Fifteen per cent, because anything smaller is indistinguishable from the
    /// variance between two windows of the same download, and keeping a
    /// connection that bought noise is how you arrive at the ceiling by accident.
    static let worthwhile = 1.15

    /// Enough completed segments to judge by. One segment is latency; several is
    /// a rate.
    static let window = 4

    /// Records one finished segment and returns the count to use from here.
    public mutating func completed(bytes: Int, seconds: Double) -> Int {
        guard bytes > 0, seconds > 0, seconds.isFinite else { return allowed }
        samples.append(Sample(bytes: bytes, seconds: seconds))
        guard samples.count >= Self.window else { return allowed }

        // Bytes over wall-clock across the window. Summing the per-segment times
        // rather than measuring elapsed is deliberate: segments overlap, so this
        // is throughput per connection, which is the thing that degrades when
        // there are too many of them.
        let bytes = samples.reduce(0) { $0 + $1.bytes }
        let seconds = samples.reduce(0) { $0 + $1.seconds }
        samples.removeAll(keepingCapacity: true)
        guard seconds > 0 else { return allowed }
        let rate = Double(bytes) / seconds

        defer { best = max(best, rate) }

        guard isClimbing, allowed < maximum else { return allowed }
        guard best > 0 else {
            // The first window is the baseline. Nothing to compare it to yet, so
            // take one step up and see.
            allowed += 1
            return allowed
        }
        if rate >= best * Self.worthwhile {
            allowed += 1
        } else {
            // It did not pay. Give back the connection that did not earn its
            // place and stop asking.
            allowed = max(1, allowed - 1)
            isClimbing = false
        }
        return allowed
    }

    /// The server pushed back: a 429, or a 5xx, or a connection it closed.
    ///
    /// Halves rather than stepping down, and stops climbing for the rest of the
    /// download. A server that is refusing concurrency will refuse it again, and
    /// the cost of finding that out twice is paid by the user waiting.
    public mutating func throttled() -> Int {
        allowed = max(1, allowed / 2)
        isClimbing = false
        samples.removeAll(keepingCapacity: true)
        return allowed
    }

    /// Whether a status means "fewer connections" rather than "this segment is
    /// broken".
    ///
    /// 429 is the explicit one. 503 is a server saying it is out of capacity,
    /// which more connections make worse. A 403 is deliberately *not* here: it
    /// means this URL is not for us, and no amount of backing off changes that.
    public static func isThrottling(status: Int) -> Bool {
        status == 429 || status == 503
    }
}

/// Seconds, as a `Double`, from one of the clock's durations.
///
/// `Duration` holds attoseconds in a second `Int64` precisely so it cannot be
/// read as a float by accident. For deciding how fast a download is going, a
/// float is exactly what is wanted, and writing the conversion out at each call
/// site is how one of them ends up dividing by the wrong power of ten.
public extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
