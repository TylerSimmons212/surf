import CoreGraphics
import Foundation

/// Where a number came from.
///
/// The spine of this pane. WebKit implements Largest Contentful Paint and paint
/// timing, and implements neither `layout-shift` nor `longtask` — measured
/// before any of this was written, and worth stating on screen rather than
/// quietly filling the gaps with numbers of our own that look identical to the
/// platform's. A metric Surf computed is a different kind of fact from one the
/// engine reported, and the difference decides how much weight to put on it.
public enum MetricSource: Sendable, Equatable {
    /// The platform reported this.
    case measured
    /// Surf worked it out, by the named method.
    case approximated(String)
    /// Not obtainable here, and why.
    case unavailable(String)
    /// Hasn't happened yet — no interaction, no shift, still loading.
    case pending(String)

    public var isMeasured: Bool { self == .measured }

    public var note: String? {
        switch self {
        case .measured: nil
        case .approximated(let how): how
        case .unavailable(let why): why
        case .pending(let what): what
        }
    }
}

public enum MetricRating: Sendable, Equatable {
    case good, needsWork, poor, unrated

    public var label: String {
        switch self {
        case .good: "Good"
        case .needsWork: "Needs work"
        case .poor: "Poor"
        case .unrated: ""
        }
    }
}

public enum MetricKind: String, Sendable, CaseIterable, Identifiable {
    case ttfb, fcp, lcp, inp, cls, blocking

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ttfb: "TTFB"
        case .fcp: "FCP"
        case .lcp: "LCP"
        case .inp: "INP"
        case .cls: "CLS"
        case .blocking: "Blocking"
        }
    }

    public var title: String {
        switch self {
        case .ttfb: "Time to first byte"
        case .fcp: "First contentful paint"
        case .lcp: "Largest contentful paint"
        case .inp: "Interaction to next paint"
        case .cls: "Cumulative layout shift"
        case .blocking: "Total blocking time"
        }
    }

    /// Good below the first, poor above the second. The Core Web Vitals
    /// thresholds, so a number here means what it means everywhere else.
    public var thresholds: (good: Double, poor: Double) {
        switch self {
        case .ttfb: (800, 1800)
        case .fcp: (1800, 3000)
        case .lcp: (2500, 4000)
        case .inp: (200, 500)
        case .cls: (0.1, 0.25)
        case .blocking: (200, 600)
        }
    }

    public var isUnitless: Bool { self == .cls }
}

public struct PerformanceMetric: Sendable, Equatable, Identifiable {
    public var kind: MetricKind
    /// Milliseconds, except CLS which is unitless. Nil when there is no value.
    public var value: Double?
    public var source: MetricSource
    /// What produced the number — the LCP element, the slowest interaction.
    public var detail: String

    public var id: String { kind.rawValue }

    public init(
        kind: MetricKind, value: Double? = nil,
        source: MetricSource = .measured, detail: String = ""
    ) {
        self.kind = kind
        self.value = value
        self.source = source
        self.detail = detail
    }

    public var rating: MetricRating {
        guard let value else { return .unrated }
        if case .unavailable = source { return .unrated }
        // An approximation is still rated: it is the best answer available on
        // this engine, and leaving it unrated invites ignoring it entirely.
        let (good, poor) = kind.thresholds
        if value <= good { return .good }
        if value <= poor { return .needsWork }
        return .poor
    }

    public var display: String {
        guard let value else { return "—" }
        if kind.isUnitless { return String(format: "%.3f", value) }
        if value < 1000 { return "\(Int(value.rounded())) ms" }
        return String(format: "%.2f s", value / 1000)
    }
}

/// One span of the navigation, for the timeline.
public struct NavigationPhase: Sendable, Equatable, Identifiable {
    public var name: String
    public var start: Double
    public var end: Double

    public var id: String { name }
    public var duration: Double { max(0, end - start) }

    public init(name: String, start: Double, end: Double) {
        self.name = name
        self.start = start
        self.end = end
    }
}

/// A moment worth a marker rather than a bar.
public struct NavigationMarker: Sendable, Equatable, Identifiable {
    public var name: String
    public var at: Double

    public var id: String { name }

    public init(name: String, at: Double) {
        self.name = name
        self.at = at
    }
}

/// One layout shift, as observed or approximated.
public struct LayoutShift: Sendable, Equatable, Identifiable {
    public var at: Double
    public var value: Double
    public var describedBy: String

    public var id: String { "\(at)" }

    public init(at: Double, value: Double, describedBy: String = "") {
        self.at = at
        self.value = value
        self.describedBy = describedBy
    }
}

/// A stretch where the main thread didn't come back.
public struct BlockingEvent: Sendable, Equatable, Identifiable {
    public var at: Double
    public var duration: Double

    public var id: String { "\(at)" }

    public init(at: Double, duration: Double) {
        self.at = at
        self.duration = duration
    }

    /// What a long task contributes to total blocking time: everything past the
    /// 50ms that is considered acceptable.
    public var blockingTime: Double { max(0, duration - 50) }
}

/// Cumulative Layout Shift, as the metric is actually defined.
///
/// Not a running total, which is what a naive implementation produces and what
/// makes any long-lived page score arbitrarily badly. CLS is the *largest
/// session window*: shifts group into windows that end after a one-second gap
/// or five seconds of wall clock, whichever comes first, and the score is the
/// biggest window's sum.
public enum CumulativeLayoutShift {

    public static func score(_ shifts: [LayoutShift]) -> Double {
        guard !shifts.isEmpty else { return 0 }
        let ordered = shifts.sorted { $0.at < $1.at }

        var best = 0.0
        var current = 0.0
        var windowStart = ordered[0].at
        var previous = ordered[0].at

        for shift in ordered {
            let gap = shift.at - previous
            let span = shift.at - windowStart
            if gap >= 1000 || span >= 5000 {
                best = max(best, current)
                current = 0
                windowStart = shift.at
            }
            current += shift.value
            previous = shift.at
        }
        return max(best, current)
    }

    /// The spec's formula: how much of the viewport moved, times how far.
    ///
    /// Both factors matter. A small element crossing the whole screen and a
    /// full-width banner nudging by one pixel are very different experiences,
    /// and either factor alone would call one of them fine.
    public static func impact(
        before: CGRect, after: CGRect, viewport: CGSize
    ) -> Double {
        guard viewport.width > 0, viewport.height > 0 else { return 0 }
        let union = before.union(after)
        let impactFraction = (union.width * union.height)
            / (viewport.width * viewport.height)
        let distance = max(
            abs(after.minX - before.minX), abs(after.minY - before.minY)
        )
        let distanceFraction = distance / max(viewport.width, viewport.height)
        return min(1, impactFraction) * min(1, distanceFraction)
    }
}

public enum TotalBlockingTime {
    /// Everything past 50ms in each long task, which is the metric's definition.
    public static func total(_ events: [BlockingEvent]) -> Double {
        events.reduce(0) { $0 + $1.blockingTime }
    }
}
