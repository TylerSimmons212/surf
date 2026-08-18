import Foundation

public struct PerformanceReport: Sendable, Equatable {
    public var metrics: [PerformanceMetric]
    public var phases: [NavigationPhase]
    public var markers: [NavigationMarker]
    public var shifts: [LayoutShift]
    public var blocking: [BlockingEvent]
    /// True while the layout watcher is running, so the pane can say that CLS
    /// is still accumulating rather than final.
    public var isWatchingLayout: Bool
    public var span: Double

    public init(
        metrics: [PerformanceMetric] = [],
        phases: [NavigationPhase] = [],
        markers: [NavigationMarker] = [],
        shifts: [LayoutShift] = [],
        blocking: [BlockingEvent] = [],
        isWatchingLayout: Bool = false,
        span: Double = 0
    ) {
        self.metrics = metrics
        self.phases = phases
        self.markers = markers
        self.shifts = shifts
        self.blocking = blocking
        self.isWatchingLayout = isWatchingLayout
        self.span = span
    }

    public func metric(_ kind: MetricKind) -> PerformanceMetric? {
        metrics.first { $0.kind == kind }
    }
}

public enum PerformanceWire {

    public static func decode(_ body: [String: Any]) -> PerformanceReport {
        let support = body["support"] as? [String: Any] ?? [:]
        let navigation = body["navigation"] as? [String: Any]
        func timing(_ key: String) -> Double? {
            guard let value = navigation?[key] as? Double else { return nil }
            // Zero means "this phase didn't happen" for most navigation fields
            // — no redirect, no TLS — rather than "it happened instantly".
            return value > 0 ? value : nil
        }

        let shifts = (body["shifts"] as? [[String: Any]] ?? []).compactMap { entry -> LayoutShift? in
            guard let at = entry["at"] as? Double, let value = entry["value"] as? Double
            else { return nil }
            return LayoutShift(
                at: at, value: value, describedBy: entry["describedBy"] as? String ?? ""
            )
        }
        let blocking = (body["blocking"] as? [[String: Any]] ?? []).compactMap {
            entry -> BlockingEvent? in
            guard let at = entry["at"] as? Double, let duration = entry["duration"] as? Double
            else { return nil }
            return BlockingEvent(at: at, duration: duration)
        }

        var metrics: [PerformanceMetric] = []

        metrics.append(PerformanceMetric(
            kind: .ttfb, value: timing("responseStart"), source: .measured
        ))

        metrics.append(PerformanceMetric(
            kind: .fcp,
            value: body["fcp"] as? Double,
            source: (support["paint"] as? Bool ?? false)
                ? .measured : .unavailable("paint timing isn't implemented here")
        ))

        // Reported by WebKit, but only for a page that was actually visible —
        // so an absent value means "not yet", not "unavailable".
        let lcp = body["lcp"] as? [String: Any]
        metrics.append(PerformanceMetric(
            kind: .lcp,
            value: lcp?["at"] as? Double,
            source: (support["lcp"] as? Bool ?? false)
                ? (lcp == nil ? .pending("no contentful paint recorded yet") : .measured)
                : .unavailable("not implemented here"),
            detail: (lcp?["element"] as? String) ?? ""
        ))

        let interaction = body["interaction"] as? [String: Any]
        metrics.append(PerformanceMetric(
            kind: .inp,
            value: interaction?["duration"] as? Double,
            source: (support["event"] as? Bool ?? false)
                ? (interaction == nil ? .pending("no interactions yet — try clicking") : .measured)
                : .unavailable("event timing isn't implemented here"),
            detail: (interaction?["name"] as? String) ?? ""
        ))

        // The two WebKit doesn't implement, and the reason this pane says where
        // every number came from.
        let hasNativeShift = support["layoutShift"] as? Bool ?? false
        let watching = body["watching"] as? Bool ?? false
        metrics.append(PerformanceMetric(
            kind: .cls,
            value: shifts.isEmpty && !watching ? nil : CumulativeLayoutShift.score(shifts),
            source: hasNativeShift
                ? .measured
                : (watching || !shifts.isEmpty
                    ? .approximated("watched for elements moving — WebKit reports no layout shifts")
                    : .pending("not measuring yet")),
            detail: shifts.isEmpty ? "" : "\(shifts.count) shifts"
        ))

        let hasNativeLongTask = support["longtask"] as? Bool ?? false
        metrics.append(PerformanceMetric(
            kind: .blocking,
            value: TotalBlockingTime.total(blocking),
            source: hasNativeLongTask
                ? .measured
                : .approximated("watched for the scheduler stalling — WebKit reports no long tasks"),
            detail: blocking.isEmpty ? "" : "\(blocking.count) long tasks"
        ))

        // Phases, skipping the ones that didn't happen: a redirect span of zero
        // drawn as a bar reads as a redirect that took no time.
        var phases: [NavigationPhase] = []
        func phase(_ name: String, _ start: String, _ end: String) {
            guard let from = timing(start), let to = timing(end), to > from else { return }
            phases.append(NavigationPhase(name: name, start: from, end: to))
        }
        phase("Redirect", "redirectStart", "redirectEnd")
        phase("DNS", "domainLookupStart", "domainLookupEnd")
        phase("Connect", "connectStart", "connectEnd")
        phase("TLS", "secureConnectionStart", "connectEnd")
        phase("Request", "requestStart", "responseStart")
        phase("Response", "responseStart", "responseEnd")
        phase("DOM", "responseEnd", "domInteractive")

        var markers: [NavigationMarker] = []
        func marker(_ name: String, _ key: String) {
            guard let at = timing(key) else { return }
            markers.append(NavigationMarker(name: name, at: at))
        }
        marker("DOM interactive", "domInteractive")
        marker("DOMContentLoaded", "domContentLoadedEventEnd")
        marker("Load", "loadEventEnd")
        if let fcp = body["fcp"] as? Double {
            markers.append(NavigationMarker(name: "FCP", at: fcp))
        }
        if let at = lcp?["at"] as? Double {
            markers.append(NavigationMarker(name: "LCP", at: at))
        }

        let span = max(
            markers.map(\.at).max() ?? 0,
            phases.map(\.end).max() ?? 0
        )

        return PerformanceReport(
            metrics: metrics, phases: phases, markers: markers,
            shifts: shifts, blocking: blocking,
            isWatchingLayout: watching, span: span
        )
    }
}
