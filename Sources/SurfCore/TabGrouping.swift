import Foundation

/// One tab's place in the list: which tab, and which group it belongs to.
public struct TabSlot: Equatable, Sendable {
    public var id: UUID
    /// nil for a tab filed under no group — the ordinary case.
    public var group: UUID?

    public init(id: UUID, group: UUID? = nil) {
        self.id = id
        self.group = group
    }
}

/// Reading the flat tab list as sections.
///
/// A group is not a container here. It is a *property of its tabs* plus the rule
/// that tabs sharing one sit next to each other — so the list stays one array,
/// and everything already written against it (selection, cycling, hibernation,
/// persistence) keeps working without learning what a group is.
///
/// The cost of that choice is exactly one invariant, `normalized`, and the
/// reason it's worth paying is that the alternative — a tree of tabs and
/// folders — makes every one of those callers handle two shapes forever.
public enum TabGrouping {

    /// A stretch of consecutive tabs sharing one group, or a stretch of
    /// ungrouped ones.
    public struct Run: Equatable, Sendable {
        public var group: UUID?
        public var ids: [UUID]

        public init(group: UUID?, ids: [UUID]) {
            self.group = group
            self.ids = ids
        }
    }

    /// The list as consecutive runs, in order.
    ///
    /// Ungrouped tabs come back as runs too, rather than as loose ids, so the
    /// sidebar walks one sequence instead of interleaving two.
    public static func runs(_ slots: [TabSlot]) -> [Run] {
        var runs: [Run] = []
        for slot in slots {
            if var last = runs.last, last.group == slot.group {
                last.ids.append(slot.id)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(group: slot.group, ids: [slot.id]))
            }
        }
        return runs
    }

    /// An order in which every group's tabs are contiguous, each group sitting
    /// where its first member already is. Nil when nothing needs moving.
    ///
    /// This is the repair, not the everyday path: dropping a tab beside another
    /// keeps runs whole on its own, because it lands where a member already was.
    /// What needs repairing is everything that moves a tab *without* consulting
    /// the sidebar — a split pulling its partner into place across a boundary,
    /// or a session file hand-edited or written by an older build.
    ///
    /// Anchoring on the first member matters: anchoring on the last would drag
    /// a group down the list every time it was repaired, which is a group
    /// wandering off on its own for no reason the user can see.
    public static func normalized(_ slots: [TabSlot]) -> [UUID]? {
        var order: [UUID] = []
        var placed: Set<UUID> = []

        for slot in slots {
            guard let group = slot.group else {
                order.append(slot.id)
                continue
            }
            guard !placed.contains(group) else { continue }
            placed.insert(group)
            order.append(contentsOf: slots.filter { $0.group == group }.map(\.id))
        }

        return order == slots.map(\.id) ? nil : order
    }

    /// The ids in one group, in list order.
    public static func members(of group: UUID, in slots: [TabSlot]) -> [UUID] {
        slots.filter { $0.group == group }.map(\.id)
    }
}
