import Foundation

/// Everything the page can say about one element's styles, in one reply.
public struct MatchedStylesPayload: Sendable {
    public var rules: [MatchedRule]
    /// The document's `@layer` order, first declared first.
    public var layerOrder: [String]
    /// Every computed property, resolved.
    public var computed: [String: String]
    /// Custom properties in force on the element, resolved to their values.
    public var variables: [String: String]
    /// Stylesheets the page is forbidden to read, by URL.
    ///
    /// A cross-origin sheet throws `SecurityError` on `.cssRules`, so no
    /// JS-based inspector can show a single rule from it — Chrome and Safari
    /// both silently show nothing, which looks identical to "this element has
    /// no styles from there". Naming them is the first half of the fix; the
    /// second is refetching them natively, which `URLSession` can do because it
    /// is not bound by CORS at all.
    public var unreadableSheets: [String]

    public init(
        rules: [MatchedRule] = [],
        layerOrder: [String] = [],
        computed: [String: String] = [:],
        variables: [String: String] = [:],
        unreadableSheets: [String] = []
    ) {
        self.rules = rules
        self.layerOrder = layerOrder
        self.computed = computed
        self.variables = variables
        self.unreadableSheets = unreadableSheets
    }
}

public enum CSSWire {

    public static func decodeMatchedStyles(_ body: [String: Any]) -> MatchedStylesPayload {
        MatchedStylesPayload(
            rules: (body["rules"] as? [[String: Any]] ?? []).compactMap(decodeRule),
            layerOrder: body["layers"] as? [String] ?? [],
            computed: body["computed"] as? [String: String] ?? [:],
            variables: body["variables"] as? [String: String] ?? [:],
            unreadableSheets: body["unreadable"] as? [String] ?? []
        )
    }

    public static func decodeRule(_ value: Any?) -> MatchedRule? {
        guard let dict = value as? [String: Any], let id = dict["id"] as? Int else { return nil }

        let selector = dict["selector"] as? String ?? ""
        let matched = dict["matched"] as? String ?? selector
        let isStyleAttribute = dict["inline"] as? Bool ?? false

        return MatchedRule(
            id: id,
            selector: selector,
            matchedSelector: matched,
            // The style attribute has no selector and therefore no weight of
            // its own; it wins by sitting in a layer after every other one.
            specificity: isStyleAttribute ? .zero : CSSSpecificity.calculate(matched),
            origin: CSSOrigin(rawValue: dict["origin"] as? String ?? "") ?? .author,
            layer: (dict["layer"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            conditions: dict["conditions"] as? [String] ?? [],
            href: (dict["href"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            sourceLabel: dict["label"] as? String ?? "",
            sourceOrder: dict["order"] as? Int ?? 0,
            declarations: decodeDeclarations(dict["declarations"]),
            pseudoElement: (dict["pseudo"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            states: dict["states"] as? [String] ?? [],
            isStyleAttribute: isStyleAttribute,
            inheritDistance: max(0, dict["distance"] as? Int ?? 0),
            inheritedLabel: (dict["from"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isRecovered: dict["recovered"] as? Bool ?? false
        )
    }

    public static func decodeDeclarations(_ value: Any?) -> [CSSDeclaration] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.enumerated().compactMap { index, entry in
            guard let name = entry["name"] as? String, !name.isEmpty else { return nil }
            return CSSDeclaration(
                index: index,
                name: name,
                value: entry["value"] as? String ?? "",
                isImportant: entry["important"] as? Bool ?? false,
                // Absent means the page couldn't expand it — a custom property,
                // or a shorthand the engine doesn't recognise. Standing for
                // itself is right in both cases.
                longhands: entry["longhands"] as? [String] ?? [name]
            )
        }
    }
}
