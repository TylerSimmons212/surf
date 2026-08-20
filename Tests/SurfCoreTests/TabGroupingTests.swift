import Foundation
import Testing
@testable import SurfCore

@Suite("Tab grouping")
struct TabGroupingTests {

    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let work = UUID(), play = UUID()

    private func slots(_ pairs: [(UUID, UUID?)]) -> [TabSlot] {
        pairs.map { TabSlot(id: $0.0, group: $0.1) }
    }

    // MARK: - Runs

    @Test("Ungrouped tabs come back as one run")
    func runsUngrouped() {
        let runs = TabGrouping.runs(slots([(a, nil), (b, nil)]))
        #expect(runs == [.init(group: nil, ids: [a, b])])
    }

    @Test("A group breaks the list into runs around it")
    func runsAroundGroup() {
        let runs = TabGrouping.runs(slots([(a, nil), (b, work), (c, work), (d, nil)]))
        #expect(runs == [
            .init(group: nil, ids: [a]),
            .init(group: work, ids: [b, c]),
            .init(group: nil, ids: [d]),
        ])
    }

    /// Two groups touching must stay two runs — merging them would draw one
    /// section holding another group's tabs.
    @Test("Adjacent groups stay separate runs")
    func keepsAdjacentGroupsApart() {
        let runs = TabGrouping.runs(slots([(a, work), (b, play)]))
        #expect(runs == [
            .init(group: work, ids: [a]),
            .init(group: play, ids: [b]),
        ])
    }

    /// The same group appearing twice is exactly what `normalized` exists to
    /// prevent — but `runs` must still describe it truthfully rather than
    /// quietly merging the halves, or a broken list would render as a fine one.
    @Test("A split group is reported as the two runs it really is")
    func reportsSplitGroupHonestly() {
        let runs = TabGrouping.runs(slots([(a, work), (b, nil), (c, work)]))
        #expect(runs.count == 3)
        #expect(runs.map(\.group) == [work, nil, work])
    }

    @Test("An empty list has no runs")
    func handlesEmpty() {
        #expect(TabGrouping.runs([]).isEmpty)
    }

    // MARK: - Normalizing

    @Test("An already-contiguous list needs no repair")
    func leavesContiguousAlone() {
        #expect(TabGrouping.normalized(slots([(a, nil), (b, work), (c, work)])) == nil)
    }

    @Test("A scattered group is gathered at its first member")
    func gathersAtFirstMember() {
        // work sits at 0 and 2; it gathers at 0, and `b` follows.
        #expect(TabGrouping.normalized(slots([(a, work), (b, nil), (c, work)])) == [a, c, b])
    }

    /// Anchoring on the last member instead would walk the group down the list
    /// every time it was repaired.
    @Test("Repair never moves a group past where it already started")
    func anchorsOnFirstNotLast() {
        let order = TabGrouping.normalized(slots([(a, nil), (b, work), (c, nil), (d, work)]))
        #expect(order == [a, b, d, c])
    }

    @Test("Two scattered groups each gather at their own first member")
    func gathersTwoGroups() {
        let order = TabGrouping.normalized(
            slots([(a, work), (b, play), (c, work), (d, play)])
        )
        #expect(order == [a, c, b, d])
    }

    @Test("Repair keeps every tab exactly once")
    func preservesMembership() {
        let input = slots([(a, work), (b, nil), (c, work), (d, play)])
        let order = TabGrouping.normalized(input)
        #expect(order?.count == 4)
        #expect(order.map(Set.init) == Set([a, b, c, d]))
    }

    @Test("A repaired list needs no second repair")
    func repairIsIdempotent() {
        let input = slots([(a, work), (b, nil), (c, work)])
        let order = TabGrouping.normalized(input)!
        let groupOf = Dictionary(uniqueKeysWithValues: input.map { ($0.id, $0.group) })
        let repaired = order.map { TabSlot(id: $0, group: groupOf[$0] ?? nil) }
        #expect(TabGrouping.normalized(repaired) == nil)
    }

    // MARK: - Members

    @Test("Members come back in list order")
    func listsMembers() {
        let input = slots([(c, work), (b, nil), (a, work)])
        #expect(TabGrouping.members(of: work, in: input) == [c, a])
        #expect(TabGrouping.members(of: play, in: input).isEmpty)
    }
}
