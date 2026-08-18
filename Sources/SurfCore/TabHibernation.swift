import Foundation

/// Which tabs should give their web view back.
///
/// A `WKWebView` costs a web content process whether or not anything is on
/// screen, so a session of fifty tabs is fifty processes even when
/// forty-nine of them haven't been looked at since this morning. Sleeping one
/// returns the process and keeps everything the sidebar draws — title, icon,
/// address — so the only cost is that returning to it reloads the page.
///
/// The rules live here, away from WebKit, so they can be argued with in tests
/// rather than by opening fifty tabs and watching Activity Monitor.
public enum TabHibernation {

    /// A tab, as far as this decision is concerned.
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        /// When the tab was last on screen. Nil means it has never been shown,
        /// which makes it the *best* thing to sleep — it holds a web view that
        /// has never displayed anything.
        public let lastViewedAt: Date?
        /// Whether it currently holds a web view. Anything else is already
        /// asleep and costs nothing.
        public let isLive: Bool
        /// Selected, playing media, or popped out. Never slept, whatever the
        /// clock says — sleeping these would stop audio mid-track or blank the
        /// page being read.
        public let isProtected: Bool

        public init(id: UUID, lastViewedAt: Date?, isLive: Bool, isProtected: Bool) {
            self.id = id
            self.lastViewedAt = lastViewedAt
            self.isLive = isLive
            self.isProtected = isProtected
        }
    }

    /// How long a tab sits unviewed before it's worth reclaiming.
    ///
    /// Long enough that flipping between a handful of tabs while working never
    /// reaches it, short enough that a morning's browsing isn't still resident
    /// at lunch.
    public static let idleThreshold: TimeInterval = 30 * 60

    /// The most live tabs to keep regardless of age.
    ///
    /// A backstop for the case the clock can't catch: someone who opens sixty
    /// tabs in one burst has sixty *recent* tabs, all under the threshold and
    /// all holding a process. Set well above the number anyone is genuinely
    /// working with at once, so ordinary use never reaches it.
    public static let liveBudget = 20

    /// The tabs to put to sleep, oldest first.
    ///
    /// Two independent reasons, unioned: a tab that has gone stale, and a tab
    /// pushed out of the budget by newer ones. Protected tabs are excluded from
    /// the result but still *count* against the budget — they're holding real
    /// processes, and pretending otherwise would let a session of playing tabs
    /// quietly exceed it.
    public static func tabsToSleep(
        among candidates: [Candidate],
        now: Date,
        idleThreshold: TimeInterval = TabHibernation.idleThreshold,
        liveBudget: Int = TabHibernation.liveBudget
    ) -> [UUID] {
        let live = candidates.filter(\.isLive)
        let sleepable = live.filter { !$0.isProtected }

        // Least recently used first. A tab never shown sorts before everything,
        // since it has nothing on screen to lose.
        let byAge = sleepable.sorted { left, right in
            switch (left.lastViewedAt, right.lastViewedAt) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (l?, r?): return l < r
            }
        }

        var doomed: [UUID] = []
        var chosen: Set<UUID> = []

        // Stale: unviewed for longer than the threshold.
        for tab in byAge {
            let isStale = tab.lastViewedAt.map { now.timeIntervalSince($0) >= idleThreshold } ?? true
            guard isStale else { continue }
            doomed.append(tab.id)
            chosen.insert(tab.id)
        }

        // Over budget: sleep the oldest until the live count fits, counting the
        // protected ones we can't touch.
        var remaining = live.count - doomed.count
        for tab in byAge where remaining > liveBudget {
            guard !chosen.contains(tab.id) else { continue }
            doomed.append(tab.id)
            chosen.insert(tab.id)
            remaining -= 1
        }

        return doomed
    }
}
