import SurfCore
import SwiftUI

/// What SwiftUI's reorder hands back, in terms `ListOrder` already answers.
///
/// `reorderContainer` reports a finished drag as a `ReorderDifference`: the ids
/// being carried, and where they landed — before some item, or past the last
/// one. It deliberately stops there. It does not rewrite the collection, and
/// there is no helper that does, because only the caller knows where the real
/// order lives.
///
/// Which turns out to be the whole adoption. The list operations were already
/// here, generic over the id and already under test, written for the tab list
/// and never tied to it. The thousand lines of drag contexts and drop
/// delegates around them were the part the system can now do, and this is the
/// seam between the two: four lines, no arithmetic, nothing to get wrong.
extension ReorderDifference where ItemID: Hashable {

    /// `ids` in their new order, or nil when the drag changed nothing.
    ///
    /// Nil is worth passing along rather than flattening into "write it back
    /// anyway". A drag that ends where it started is not a reorder, and
    /// persisting one would touch the session file and animate a list that
    /// nobody asked to move.
    func reordering(_ ids: [ItemID]) -> [ItemID]? {
        switch destination.position {
        case .before(let target):
            ListOrder.moving(sources, before: target, in: ids)
        case .end:
            ListOrder.movingToEnd(sources, in: ids)
        @unknown default:
            nil
        }
    }
}
