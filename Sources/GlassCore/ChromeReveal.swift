import CoreGraphics

/// Which piece of window chrome the pointer is currently asking for.
///
/// The two hover affordances — the traffic lights in the top-left corner and
/// the sidebar down the left edge — sit in overlapping territory, and both are
/// revealed by simply being near them. Something has to decide which one a
/// given pointer position means, because revealing both is never right: they
/// occupy the same corner, and a sidebar that opens every time you reach for
/// the close button is worse than no hover affordance at all.
public enum ChromeTarget: String, Equatable, Sendable, CaseIterable {
    case none
    case sidebar
    case trafficLights
}

/// What the hover zones currently report. Pure input — no view state, no timing.
public struct ChromePointer: Equatable, Sendable {
    /// The pointer is inside the top-left corner zone that owns the lights.
    public var inCorner: Bool
    /// The pointer is inside the tall strip down the window's leading edge.
    public var inEdge: Bool
    /// The pointer is over the revealed sidebar panel itself.
    public var inSidebar: Bool
    /// The sidebar spawned something still on screen — a popover, a menu.
    public var sidebarHeld: Bool

    public init(
        inCorner: Bool = false,
        inEdge: Bool = false,
        inSidebar: Bool = false,
        sidebarHeld: Bool = false
    ) {
        self.inCorner = inCorner
        self.inEdge = inEdge
        self.inSidebar = inSidebar
        self.sidebarHeld = sidebarHeld
    }
}

/// Arbitrates between the traffic-light corner and the sidebar edge.
public enum ChromeReveal {

    // MARK: - Geometry

    /// Height of the row the traffic lights sit in — macOS's own titlebar
    /// height, so the buttons land where every other Mac app puts them.
    public static let lightsRowHeight: CGFloat = 28

    /// The corner zone is deliberately larger than the three buttons it guards.
    ///
    /// The buttons span roughly x 7…72; the zone runs wider and taller so an
    /// approach from below or from the right is caught *before* the pointer is
    /// already on top of them. Undersizing this is what makes a hover
    /// affordance feel like it needs to be aimed at.
    public static let cornerZone = CGSize(width: 96, height: 34)

    /// Width of the leading strip that reveals the sidebar. Wide on purpose:
    /// the zone doesn't intercept clicks, so the only cost is opening when the
    /// pointer merely passes near the edge, which the open delay absorbs.
    public static let edgeZoneWidth: CGFloat = 28

    // MARK: - Arbitration

    /// Resolves the pointer's report into the single target to reveal.
    ///
    /// `current` matters: arbitration is not a pure function of position,
    /// because an *already open* sidebar has to be able to keep the corner.
    /// Without that, moving up into the top of an open sidebar — to reach the
    /// pin button, or the tab at the top of the list — would hand the corner to
    /// the traffic lights and collapse the panel out from under the pointer.
    ///
    /// Priority, highest first:
    ///
    /// 1. **A hold wins outright.** Something the sidebar opened is on screen;
    ///    dismissing it to show three buttons is never what was meant.
    /// 2. **An open sidebar keeps the pointer it already has.** Possession, not
    ///    position — this is the hysteresis that stops the corner flip-flopping.
    /// 3. **The corner beats the edge.** Both zones cover the top-left, and the
    ///    corner is the more specific claim, so travelling up the edge to reach
    ///    the lights arrives at the right answer rather than the sidebar.
    /// 4. Otherwise the edge or the panel reveals the sidebar.
    public static func resolve(_ pointer: ChromePointer, current: ChromeTarget) -> ChromeTarget {
        if pointer.sidebarHeld { return .sidebar }
        if current == .sidebar, pointer.inSidebar { return .sidebar }
        if pointer.inCorner { return .trafficLights }
        if pointer.inEdge || pointer.inSidebar { return .sidebar }
        return .none
    }

    // MARK: - Timing

    /// Asymmetric by design, and tuned to how a pointer actually moves: opening
    /// is nearly immediate so the chrome feels responsive, closing waits far
    /// longer so crossing the gap from a zone to the thing it revealed doesn't
    /// dismiss it mid-reach.
    ///
    /// The short open delay is also what keeps rule 3 above from being felt:
    /// a pointer travelling up the edge to the corner is usually through the
    /// edge strip before the sidebar's timer ever fires, so the sidebar never
    /// flashes on its way past.
    public static func delay(revealing target: ChromeTarget) -> Duration {
        target == .none ? closeDelay : openDelay
    }

    public static let openDelay: Duration = .milliseconds(90)
    public static let closeDelay: Duration = .milliseconds(320)

    /// How long the lights stay up on launch before fading away on their own.
    ///
    /// Long enough to be noticed and used without hunting, short enough that it
    /// reads as an introduction rather than a bar you have to wait out.
    public static let launchRevealDuration: Duration = .milliseconds(2200)
}
