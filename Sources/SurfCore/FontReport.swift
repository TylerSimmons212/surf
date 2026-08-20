import Foundation

/// What the selected element's text is actually set in — the resolved fact,
/// not the wish list `font-family` states.
///
/// The stack is the wish list; `used` is the first family that can actually
/// render, found by probing each candidate against the page's own text
/// measurement. One honest limit, carried into the UI: fallback happens per
/// *glyph*, and an element whose first family lacks a character borrows it
/// from the next family down — invisible from page script, where Firefox's
/// engine-level fonts pane can see it and ours cannot.
public struct FontReport: Sendable, Equatable {

    public struct StackEntry: Sendable, Equatable {
        public var family: String
        /// A generic family — sans-serif, system-ui — which always resolves.
        public var isGeneric: Bool
        /// Whether this family can render here at all.
        public var isAvailable: Bool

        public init(family: String, isGeneric: Bool, isAvailable: Bool) {
            self.family = family
            self.isGeneric = isGeneric
            self.isAvailable = isAvailable
        }
    }

    public struct WebFont: Sendable, Equatable {
        public var family: String
        public var weight: String
        public var style: String
        /// FontFaceSet status: loaded, loading, unloaded, error.
        public var status: String

        public init(family: String, weight: String, style: String, status: String) {
            self.family = family
            self.weight = weight
            self.style = style
            self.status = status
        }
    }

    /// The family that renders this element's text.
    public var used: String
    public var stack: [StackEntry]
    public var size: String
    public var weight: String
    public var style: String
    public var lineHeight: String
    /// Every @font-face the page declared, page-wide, with load status —
    /// the place a webfont that silently failed to load shows its face.
    public var webfonts: [WebFont]

    public init(
        used: String = "",
        stack: [StackEntry] = [],
        size: String = "",
        weight: String = "",
        style: String = "",
        lineHeight: String = "",
        webfonts: [WebFont] = []
    ) {
        self.used = used
        self.stack = stack
        self.size = size
        self.weight = weight
        self.style = style
        self.lineHeight = lineHeight
        self.webfonts = webfonts
    }

    public static func decode(_ body: [String: Any]) -> FontReport {
        FontReport(
            used: body["used"] as? String ?? "",
            stack: (body["stack"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let family = entry["family"] as? String else { return nil }
                return StackEntry(
                    family: family,
                    isGeneric: entry["generic"] as? Bool ?? false,
                    isAvailable: entry["available"] as? Bool ?? false
                )
            },
            size: body["size"] as? String ?? "",
            weight: body["weight"] as? String ?? "",
            style: body["style"] as? String ?? "",
            lineHeight: body["lineHeight"] as? String ?? "",
            webfonts: (body["webfonts"] as? [[String: Any]] ?? []).compactMap { entry in
                guard let family = entry["family"] as? String else { return nil }
                return WebFont(
                    family: family,
                    weight: entry["weight"] as? String ?? "",
                    style: entry["style"] as? String ?? "",
                    status: entry["status"] as? String ?? ""
                )
            }
        )
    }
}
