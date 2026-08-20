import Foundation

/// Ranks the engine's property list against what someone has typed so far.
///
/// The list itself comes from the page (`CSS.propertyNames`) — the engine's
/// own vocabulary, not a shipped copy that would drift. This type only decides
/// order, and the order encodes how people actually reach for properties:
///
/// - A prefix match beats a substring match: someone who has typed `mar` is
///   on their way to `margin`, not hunting for `grid-template-areas` because
///   it contains an `ar`.
/// - Within each band, shorter first: `margin` before `margin-inline-start`,
///   because the shorthand is almost always the one being reached for, and
///   the longhands sit right below it when it isn't.
/// - Prefixed properties (`-webkit-…`) sink to the bottom of their band
///   unless the typed text itself starts with a dash. Nobody discovers
///   `-webkit-line-clamp` by accident; everyone who wants it types the dash.
public enum CSSPropertyCompletion {

    public static func matches(
        _ prefix: String,
        in names: [String],
        limit: Int = 6
    ) -> [String] {
        let needle = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }

        var starts: [String] = []
        var contains: [String] = []
        for name in names {
            let lower = name.lowercased()
            if lower == needle { continue }  // already fully typed
            if lower.hasPrefix(needle) {
                starts.append(name)
            } else if lower.contains(needle) {
                contains.append(name)
            }
        }

        func rank(_ list: [String]) -> [String] {
            list.sorted {
                let aDash = $0.hasPrefix("-"), bDash = $1.hasPrefix("-")
                if aDash != bDash, !needle.hasPrefix("-") { return bDash }
                if $0.count != $1.count { return $0.count < $1.count }
                return $0 < $1
            }
        }

        return Array((rank(starts) + rank(contains)).prefix(limit))
    }
}
