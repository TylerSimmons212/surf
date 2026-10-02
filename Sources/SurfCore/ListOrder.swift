import Foundation

/// Reordering a list by identity, as pure list operations.
///
/// Named for the tab list, which was its only caller until the sticker shelf
/// stopped hand-rolling its drags and found that the operations it needed were
/// already here, already generic, and already under test.
///
/// Index arithmetic is where reordering goes wrong: removing before inserting
/// shifts every index after the hole, and a group of two makes it worse because
/// the second removal moves the first insertion point. These work by identity on
/// a rebuilt list instead, so there is no arithmetic to get wrong.
///
/// Each returns nil when the move would change nothing — "no such tab", "the
/// target is inside the group", and "it is already there" are all answered the
/// same way, because every caller wants the same thing from all three: leave the
/// list alone, and don't report a move that didn't happen.
public enum ListOrder {

    /// `group` — in the order given — moved to sit where `target` currently is.
    public static func moving<ID: Hashable>(
        _ group: [ID],
        before target: ID,
        in order: [ID]
    ) -> [ID]? {
        let moving = Set(group)
        guard moving.count == group.count,
              !moving.contains(target),
              moving.isSubset(of: Set(order))
        else { return nil }

        var rest = order.filter { !moving.contains($0) }
        guard let at = rest.firstIndex(of: target) else { return nil }
        rest.insert(contentsOf: group, at: at)
        return rest == order ? nil : rest
    }

    /// `group` moved to the end, keeping its own order.
    public static func movingToEnd<ID: Hashable>(_ group: [ID], in order: [ID]) -> [ID]? {
        let moving = Set(group)
        guard moving.count == group.count, moving.isSubset(of: Set(order)) else { return nil }

        var rest = order.filter { !moving.contains($0) }
        rest.append(contentsOf: group)
        return rest == order ? nil : rest
    }

    /// `id` moved to sit directly after `anchor`.
    ///
    /// This is what keeps a split's two tabs next to each other in the list. The
    /// sidebar draws them as one grouped row, and a group whose members are
    /// filed three rows apart is a drawing that disagrees with the list it's
    /// drawn from — reorder anything between them and the group appears to
    /// teleport.
    /// `items` rearranged into `order`.
    ///
    /// The other three functions here work on ids, which is what keeps them
    /// free of any opinion about what is being ordered. This is the one step
    /// back: a reorder arrives as ids, and what the caller holds is items.
    ///
    /// An id in `order` that names nothing is skipped rather than faulted —
    /// a reorder and a removal can land in either sequence, and a shelf that
    /// crashed because a sticker was peeled mid-drag would be a worse answer
    /// than one that quietly leaves it out.
    public static func resequencing<Item: Identifiable>(
        _ items: [Item], into order: [Item.ID]
    ) -> [Item] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byID[$0] }
    }

    public static func placing<ID: Hashable>(
        _ id: ID,
        immediatelyAfter anchor: ID,
        in order: [ID]
    ) -> [ID]? {
        guard id != anchor, order.contains(id), order.contains(anchor) else { return nil }

        var rest = order.filter { $0 != id }
        guard let at = rest.firstIndex(of: anchor) else { return nil }
        rest.insert(id, at: at + 1)
        return rest == order ? nil : rest
    }
}
