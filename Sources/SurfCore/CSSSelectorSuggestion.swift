import Foundation

/// The selectors worth offering for "new rule on this element", most specific
/// first.
///
/// Generated rather than typed, deliberately: every candidate is built from
/// the element's own tag, id and classes, so each one is valid by
/// construction and each one *matches the element by construction*. A
/// free-typed selector can be neither, and the failure mode — a rule that
/// silently matches nothing — is exactly the kind of quiet wrongness this
/// panel keeps having to be cured of. Custom selectors can come later, with
/// live match-count feedback; until then the menu only offers truths.
public enum CSSSelectorSuggestion {

    public static func candidates(
        tag: String, id: String?, classes: [String]
    ) -> [String] {
        let tag = tag.lowercased()
        let cleanClasses = classes
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var out: [String] = []
        func add(_ selector: String) {
            if !selector.isEmpty, !out.contains(selector) { out.append(selector) }
        }

        if let id, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            add("#\(escape(id))")
        }
        if !cleanClasses.isEmpty {
            add(tag + cleanClasses.map { ".\(escape($0))" }.joined())
            // The single most reusable form: the first class alone, which is
            // usually the component's name.
            add(".\(escape(cleanClasses[0]))")
        }
        if !tag.isEmpty, !tag.hasPrefix("#") {
            add(tag)
        }
        return out
    }

    /// CSS.escape's essentials: enough that a class like `1/2` or `a:b`
    /// survives being put in a selector.
    ///
    /// Not the full algorithm — no surrogate handling, no NULL replacement —
    /// because the input is an attribute the page already carries, not
    /// arbitrary text. Anything alphanumeric passes untouched; a leading
    /// digit and any other character get a backslash.
    static func escape(_ identifier: String) -> String {
        var out = ""
        for (index, scalar) in identifier.unicodeScalars.enumerated() {
            let isWord = scalar == "_" || scalar == "-"
                || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar)
            if ("0"..."9").contains(scalar), index == 0 {
                out += "\\3\(scalar) "
            } else if isWord || scalar.value > 0x7F {
                out.unicodeScalars.append(scalar)
            } else {
                out += "\\\(scalar)"
            }
        }
        return out
    }
}
