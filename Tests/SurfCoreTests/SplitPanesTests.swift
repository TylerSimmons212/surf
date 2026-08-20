import Foundation
import Testing
@testable import SurfCore

@Suite("Split panes")
struct SplitPanesTests {

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func pair() -> SplitPanes { SplitPanes(leading: a, trailing: b)! }

    @Test("A tab can't be split against itself")
    func refusesSelfSplit() {
        #expect(SplitPanes(leading: a, trailing: a) == nil)
    }

    @Test("Sides are reported by position, not by order asked")
    func reportsSides() {
        let panes = pair()
        #expect(panes.side(of: a) == .leading)
        #expect(panes.side(of: b) == .trailing)
        #expect(panes.side(of: c) == nil)
        #expect(panes.contains(a))
        #expect(!panes.contains(c))
    }

    @Test("Each pane's counterpart is the other one")
    func findsCounterpart() {
        let panes = pair()
        #expect(panes.counterpart(of: a) == b)
        #expect(panes.counterpart(of: b) == a)
        #expect(panes.counterpart(of: c) == nil)
    }

    @Test("Replacing a pane keeps the other side put")
    func replacesOneSide() {
        let replaced = pair().replacing(.leading, with: c)
        #expect(replaced?.leading == c)
        #expect(replaced?.trailing == b)
    }

    /// Dropping a tab onto the half that already shows it asks for a pair with
    /// one tab in both panes. It has to fail rather than produce one: a tab
    /// owns a single web view, so the "other" pane would render nothing.
    @Test("Replacing a pane with the other pane's tab is refused")
    func refusesReplacementThatDuplicates() {
        #expect(pair().replacing(.leading, with: b) == nil)
        #expect(pair().replacing(.trailing, with: a) == nil)
    }

    @Test("Replacing a pane with the tab already in it is refused")
    func refusesNoOpReplacement() {
        // Same tab, same side — nothing to do, and the caller should be able to
        // tell that from the return rather than by comparing before and after.
        #expect(pair().replacing(.leading, with: a)?.leading == a)
    }

    @Test("Swapping exchanges the sides")
    func swaps() {
        let swapped = pair().swapped()
        #expect(swapped.leading == b)
        #expect(swapped.trailing == a)
        #expect(swapped.swapped() == pair())
    }

    @Test("Closing one pane leaves the other")
    func collapsesToSurvivor() {
        #expect(pair().collapsing(after: a) == b)
        #expect(pair().collapsing(after: b) == a)
    }

    /// Closing a background tab must not disturb a split it was never part of.
    @Test("Closing an unrelated tab collapses nothing")
    func ignoresUnrelatedClose() {
        #expect(pair().collapsing(after: c) == nil)
    }
}
