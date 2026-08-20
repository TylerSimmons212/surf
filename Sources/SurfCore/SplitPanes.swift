import Foundation

/// The two pages shown side by side, identified by tab.
///
/// Position only. Which of the two is *focused* is the session's selection and
/// deliberately isn't stored here: the panes must hold still while focus moves
/// between them, so the two facts are kept apart rather than derived from each
/// other.
public struct SplitPanes: Equatable, Sendable {
    public var leading: UUID
    public var trailing: UUID

    /// Fails rather than trapping when handed the same tab twice. A tab owns
    /// one `WKWebView` and a view can only be in one place, so a self-split
    /// wouldn't render two pages — it would move one page into the pane it was
    /// already in and leave the other blank.
    public init?(leading: UUID, trailing: UUID) {
        guard leading != trailing else { return nil }
        self.leading = leading
        self.trailing = trailing
    }

    /// Which side, if either, this tab occupies.
    public func side(of id: UUID) -> Side? {
        if id == leading { return .leading }
        if id == trailing { return .trailing }
        return nil
    }

    public func contains(_ id: UUID) -> Bool { side(of: id) != nil }

    public func tab(on side: Side) -> UUID {
        switch side {
        case .leading: leading
        case .trailing: trailing
        }
    }

    /// The other pane's tab, given one of them.
    public func counterpart(of id: UUID) -> UUID? {
        switch side(of: id) {
        case .leading: trailing
        case .trailing: leading
        case nil: nil
        }
    }

    /// This pair with `newID` installed on `side`.
    ///
    /// Returns nil when that would put one tab in both panes — which is what
    /// dropping a tab onto the half it is already showing asks for, and the
    /// answer there is to change nothing.
    public func replacing(_ side: Side, with newID: UUID) -> SplitPanes? {
        switch side {
        case .leading: SplitPanes(leading: newID, trailing: trailing)
        case .trailing: SplitPanes(leading: leading, trailing: newID)
        }
    }

    public func swapped() -> SplitPanes {
        // Non-nil by construction: the two are distinct, so the swap is too.
        SplitPanes(leading: trailing, trailing: leading)!
    }

    /// What the window should show once `closing` goes away: the surviving
    /// pane's tab, or nil if this pair had nothing to do with it.
    ///
    /// Returned rather than mutated because closing half a split doesn't shrink
    /// the split, it *ends* it — the survivor goes back to filling the window.
    public func collapsing(after closing: UUID) -> UUID? {
        counterpart(of: closing)
    }

    public enum Side: Equatable, Sendable {
        case leading
        case trailing
    }
}
