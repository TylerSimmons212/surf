import CoreGraphics

/// What the hover zones currently report. Pure input — no view state, no timing.
public struct ChromePointer: Equatable, Sendable {
    /// The pointer is inside the tall strip down the window's leading edge.
    public var inEdge: Bool
    /// The pointer is over the revealed sidebar panel itself.
    public var inSidebar: Bool
    /// The sidebar spawned something still on screen — a popover, a menu.
    public var sidebarHeld: Bool

    public init(
        inEdge: Bool = false,
        inSidebar: Bool = false,
        sidebarHeld: Bool = false
    ) {
        self.inEdge = inEdge
        self.inSidebar = inSidebar
        self.sidebarHeld = sidebarHeld
    }
}

/// Decides when the sidebar — the window's one piece of hover chrome — shows.
///
/// The traffic lights need no say of their own: they live in the sidebar's own
/// top row now, beside the window controls they belong with, so they appear
/// and disappear with the panel. There used to be an arbitration here between
/// the lights' corner and the sidebar's edge; giving the lights to the sidebar
/// dissolved it — one zone, one panel, one decision. Their geometry went with
/// them, to `Sidebar`, which is what actually lays that row out.
public enum ChromeReveal {

    // MARK: - Geometry

    /// Width of the leading strip that reveals the sidebar. Wide on purpose:
    /// the zone doesn't intercept clicks, so the only cost is opening when the
    /// pointer merely passes near the edge, which the open delay absorbs.
    public static let edgeZoneWidth: CGFloat = 28

    // MARK: - The decision

    /// Whether the pointer's report asks for the sidebar.
    ///
    /// A hold — a popover or menu the sidebar opened, still on screen — keeps
    /// it up with the pointer anywhere at all: dismissing chrome out from
    /// under its own popover is never what was meant.
    public static func shouldReveal(_ pointer: ChromePointer) -> Bool {
        pointer.sidebarHeld || pointer.inSidebar || pointer.inEdge
    }

    // MARK: - Timing

    /// Asymmetric by design, and tuned to how a pointer actually moves: opening
    /// is nearly immediate so the chrome feels responsive, closing waits far
    /// longer so crossing the gap from the edge zone to the panel it revealed
    /// doesn't dismiss it mid-reach.
    public static func delay(revealing: Bool) -> Duration {
        revealing ? openDelay : closeDelay
    }

    public static let openDelay: Duration = .milliseconds(90)
    public static let closeDelay: Duration = .milliseconds(320)

    /// How long the sidebar stays up on launch before tucking away on its own.
    ///
    /// The window opens with no chrome at all otherwise — and the sidebar is
    /// where everything lives now, the window controls included, so its one
    /// unprompted appearance is what teaches the edge is worth reaching for.
    public static let launchRevealDuration: Duration = .milliseconds(2200)
}
