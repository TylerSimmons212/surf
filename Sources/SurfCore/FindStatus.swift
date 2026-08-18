/// What the find bar says next to the field.
public enum FindStatus {

    /// Nothing at all until something has been typed — a bar that says "No
    /// results" the moment it opens reads as an error before any question was
    /// asked.
    public static func summary(query: String, matches: Int) -> String {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        switch matches {
        case ..<1: return "No results"
        case 1: return "1 match"
        default: return "\(matches) matches"
        }
    }

    public static func hasResults(query: String, matches: Int) -> Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty && matches > 0
    }
}
