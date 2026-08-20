import EventKit
import Foundation

/// Sends a recipe's remaining ingredients to Reminders.
///
/// The flow this completes: the checkboxes are the pantry check — tick what
/// you already have — and this carries the *rest* to the grocery list, at
/// whatever scale the recipe is set to. Items land in a list called
/// "Groceries" (found or created), because that's the list the Reminders app
/// treats as one; failing that, the default list, because a reminder in the
/// wrong list still beats a lost ingredient.
@MainActor
final class GroceryList {
    static let shared = GroceryList()

    enum Outcome: Equatable {
        case added(count: Int, list: String)
        /// Access refused — by the user, or by TCC in an unbundled dev run.
        case denied
        case failed
    }

    /// One store for the app's lifetime: each instance re-establishes the
    /// XPC connection to the reminders daemon, and access grants attach to it.
    private let store = EKEventStore()

    private init() {}

    /// - Parameter note: attached to every reminder — the recipe's name and
    ///   address, so an item in the aisle can say why it's there.
    func add(items: [String], note: String) async -> Outcome {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            debugLog("groceries: access request failed — \(error)")
            return .denied
        }
        guard granted else { return .denied }

        guard let calendar = groceriesCalendar() else { return .failed }
        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = item
            reminder.notes = note
            reminder.calendar = calendar
            do {
                try store.save(reminder, commit: false)
            } catch {
                debugLog("groceries: couldn't stage \"\(item)\" — \(error)")
            }
        }
        do {
            try store.commit()
        } catch {
            debugLog("groceries: commit failed — \(error)")
            return .failed
        }
        debugLog("groceries: added \(items.count) to \(calendar.title)")
        return .added(count: items.count, list: calendar.title)
    }

    /// The "Groceries" list, found or made. Matching by name is deliberate:
    /// EventKit can't see Reminders' grocery-list *type*, but the list users
    /// actually keep is called Groceries — and if it's typed as one there,
    /// items added here get its aisle sorting for free.
    private func groceriesCalendar() -> EKCalendar? {
        let existing = store.calendars(for: .reminder).first {
            $0.title.caseInsensitiveCompare("Groceries") == .orderedSame
        }
        if let existing { return existing }

        let created = EKCalendar(for: .reminder, eventStore: store)
        created.title = "Groceries"
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first
        else { return store.defaultCalendarForNewReminders() }
        created.source = source
        do {
            try store.saveCalendar(created, commit: true)
            return created
        } catch {
            debugLog("groceries: couldn't create a Groceries list — \(error)")
            // The wrong list still beats a lost ingredient.
            return store.defaultCalendarForNewReminders()
        }
    }
}
