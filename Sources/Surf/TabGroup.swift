import Foundation
import Observation
import SurfCore

/// A named, collapsible section of the tab list.
///
/// Deliberately holds no tabs. Membership lives on the tabs themselves — a
/// group is the run of consecutive tabs naming it — so there is exactly one
/// copy of it, and no way for a list here and a field there to disagree about
/// which tabs are in what. Everything already written against the flat tab
/// array keeps working: selection, cycling, hibernation and persistence never
/// learn that groups exist.
///
/// The price is one invariant — a group's tabs must stay contiguous — paid in
/// `Island.normalizeGroups()`.
@Observable
@MainActor
final class TabGroup: Identifiable {
    nonisolated let id: UUID
    var name: String
    var isCollapsed: Bool

    init(id: UUID = UUID(), name: String, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
    }

    convenience init(_ persisted: PersistedTabGroup) {
        self.init(id: persisted.id, name: persisted.name, isCollapsed: persisted.isCollapsed)
    }

    var snapshot: PersistedTabGroup {
        PersistedTabGroup(id: id, name: name, isCollapsed: isCollapsed)
    }

    /// What a group is called before anyone names it. Numbered by the caller,
    /// because "New Group" three times over is three sections nobody can tell
    /// apart in a collapsed sidebar.
    static func defaultName(existing: [TabGroup]) -> String {
        let taken = Set(existing.map(\.name))
        guard taken.contains("New Group") else { return "New Group" }
        var n = 2
        while taken.contains("New Group \(n)") { n += 1 }
        return "New Group \(n)"
    }
}
