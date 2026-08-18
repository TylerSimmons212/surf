import Observation
import SwiftUI

/// Reasons the sidebar must stay revealed even though the pointer has left it.
///
/// The sidebar closes when the pointer leaves — which is right for a hover
/// affordance, but wrong the moment something it opened lives *outside* it.
/// A popover is presented in its own window, so reaching for a button inside
/// the popover reads as leaving the sidebar: it collapses, the anchor goes with
/// it, and the popover is dismissed before it can be clicked.
///
/// Anything transient the sidebar spawns registers a hold for as long as it's
/// on screen. Holds are keyed so several can be outstanding at once and each
/// only clears its own.
@Observable
@MainActor
final class SidebarHold {
    private var reasons: Set<String> = []

    var isHeld: Bool { !reasons.isEmpty }

    func set(_ reason: String, _ isHolding: Bool) {
        if isHolding {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
    }

    /// A binding whose value *is* the hold, so presentation state and the hold
    /// can't drift apart — drive `.popover(isPresented:)` with this directly
    /// rather than mirroring it into a separate flag.
    func binding(for reason: String) -> Binding<Bool> {
        Binding(
            get: { self.reasons.contains(reason) },
            set: { self.set(reason, $0) }
        )
    }
}
