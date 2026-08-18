import Foundation

/// Where a rule came from. The cascade consults this before it consults
/// anything else, which is why a browser default can never beat a page style
/// no matter how specific the browser's own selector is.
public enum CSSOrigin: String, Sendable, Equatable, CaseIterable {
    case userAgent
    case user
    case author

    public var label: String {
        switch self {
        case .userAgent: "browser default"
        case .user: "user stylesheet"
        case .author: "page"
        }
    }
}

/// One `name: value` pair as it was written.
///
/// `longhands` is the same declaration as the engine actually resolves it:
/// `margin: 4px` is one authored declaration and four longhands, and the
/// cascade is decided entirely on the longhands. Keeping both is what lets the
/// panel show what someone wrote while striking through only the parts of it
/// that actually lost — `margin` with just its top overridden is a completely
/// different situation from `margin` losing outright, and every devtools shows
/// them identically.
public struct CSSDeclaration: Sendable, Equatable, Identifiable {
    public var index: Int
    public var name: String
    public var value: String
    public var isImportant: Bool
    public var longhands: [String]

    public var id: Int { index }

    public init(
        index: Int,
        name: String,
        value: String,
        isImportant: Bool = false,
        longhands: [String] = []
    ) {
        self.index = index
        self.name = name
        self.value = value
        self.isImportant = isImportant
        self.longhands = longhands.isEmpty ? [name] : longhands
    }

    public var isCustomProperty: Bool { name.hasPrefix("--") }

    /// `color: red !important`
    public var text: String {
        "\(name): \(value)\(isImportant ? " !important" : "")"
    }
}

/// Points at one declaration inside one rule. Small and hashable so the view
/// can ask "is this struck through?" without carrying the rule around.
public struct DeclarationRef: Sendable, Hashable {
    public var ruleId: Int
    public var index: Int

    public init(ruleId: Int, index: Int) {
        self.ruleId = ruleId
        self.index = index
    }
}

/// A rule that applies to the selected element — or would, in a state it isn't
/// currently in.
public struct MatchedRule: Sendable, Equatable, Identifiable {
    public var id: Int
    /// The whole selector list as authored, for display.
    public var selector: String
    /// The one branch of it that actually matched, which is the branch whose
    /// weight decides the fight.
    public var matchedSelector: String
    public var specificity: Specificity
    public var origin: CSSOrigin
    /// Nil means unlayered — which, counter-intuitively, *wins* over every
    /// named layer for normal declarations.
    public var layer: String?
    /// `@media (min-width: 768px)`, outermost first.
    public var conditions: [String]
    /// The stylesheet's URL. Nil for a `<style>` block.
    public var href: String?
    public var sourceLabel: String
    /// Position in the document's flattened rule order.
    public var sourceOrder: Int
    public var declarations: [CSSDeclaration]
    /// `::before` — cascaded separately from the element itself.
    public var pseudoElement: String?
    /// Pseudo-classes that had to be removed for the selector to match, so the
    /// rule is shown but doesn't currently apply. `[":hover"]`.
    public var states: [String]
    public var isStyleAttribute: Bool
    /// 0 when the rule matched the element itself, 1 for its parent, and so on.
    /// Only inheritable properties travel, and never past a nearer declaration.
    public var inheritDistance: Int
    public var inheritedLabel: String?
    /// A stylesheet the page itself is forbidden to read. Recorded so the panel
    /// can say so — and, where the fetch succeeds, replace it with the real
    /// thing rather than leave a gap.
    public var isRecovered: Bool

    public init(
        id: Int,
        selector: String,
        matchedSelector: String? = nil,
        specificity: Specificity? = nil,
        origin: CSSOrigin = .author,
        layer: String? = nil,
        conditions: [String] = [],
        href: String? = nil,
        sourceLabel: String = "",
        sourceOrder: Int = 0,
        declarations: [CSSDeclaration] = [],
        pseudoElement: String? = nil,
        states: [String] = [],
        isStyleAttribute: Bool = false,
        inheritDistance: Int = 0,
        inheritedLabel: String? = nil,
        isRecovered: Bool = false
    ) {
        self.id = id
        self.selector = selector
        let matched = matchedSelector ?? selector
        self.matchedSelector = matched
        self.specificity = specificity ?? CSSSpecificity.calculate(matched)
        self.origin = origin
        self.layer = layer
        self.conditions = conditions
        self.href = href
        self.sourceLabel = sourceLabel
        self.sourceOrder = sourceOrder
        self.declarations = declarations
        self.pseudoElement = pseudoElement
        self.states = states
        self.isStyleAttribute = isStyleAttribute
        self.inheritDistance = inheritDistance
        self.inheritedLabel = inheritedLabel
        self.isRecovered = isRecovered
    }

    /// Whether the rule is applying right now, as opposed to being shown
    /// because it *would* apply on hover or focus.
    public var isActive: Bool { states.isEmpty }

    public var isInherited: Bool { inheritDistance > 0 }

    /// What is worth showing for this rule.
    ///
    /// For a rule matched on an ancestor, that is only the properties that
    /// actually inherit. The cascade already ignores the rest — but listing
    /// them under "inherited from div.card" states something false, and the
    /// person reading it goes off to fight a `margin-top` that was never in
    /// play. Chrome and Safari both filter here for exactly this reason.
    public var displayDeclarations: [CSSDeclaration] {
        guard isInherited else { return declarations }
        return declarations.filter {
            $0.longhands.contains(where: CSSInheritance.isInheritable)
        }
    }

    /// An inherited rule none of whose declarations travel is not a rule that
    /// reaches this element at all.
    public var hasVisibleDeclarations: Bool { !displayDeclarations.isEmpty }
}

/// Properties a child takes from its parent when it declares nothing itself.
///
/// Needed because an inherited rule contributes only these: a parent's
/// `display: flex` says nothing about its children, while its `font-family`
/// says everything. Showing the whole parent rule as though all of it applied
/// is a lie that sends people chasing declarations that were never in play.
public enum CSSInheritance {
    public static let inherited: Set<String> = [
        "azimuth", "border-collapse", "border-spacing", "caption-side", "caret-color",
        "color", "color-scheme", "cursor", "direction", "empty-cells",
        "font", "font-family", "font-feature-settings", "font-kerning",
        "font-language-override", "font-optical-sizing", "font-palette",
        "font-size", "font-size-adjust", "font-stretch", "font-style",
        "font-synthesis", "font-variant", "font-variant-alternates",
        "font-variant-caps", "font-variant-east-asian", "font-variant-emoji",
        "font-variant-ligatures", "font-variant-numeric", "font-variant-position",
        "font-variation-settings", "font-weight", "forced-color-adjust",
        "hanging-punctuation", "hyphenate-character", "hyphenate-limit-chars",
        "hyphens", "image-orientation", "image-rendering", "letter-spacing",
        "line-break", "line-height", "list-style", "list-style-image",
        "list-style-position", "list-style-type", "math-depth", "math-shift",
        "math-style", "orphans", "overflow-wrap", "paint-order", "pointer-events",
        "print-color-adjust", "quotes", "ruby-align", "ruby-position",
        "tab-size", "text-align", "text-align-last", "text-anchor",
        "text-autospace", "text-combine-upright", "text-decoration-skip-ink",
        "text-emphasis", "text-emphasis-color", "text-emphasis-position",
        "text-emphasis-style", "text-indent", "text-justify", "text-orientation",
        "text-rendering", "text-shadow", "text-size-adjust", "text-spacing-trim",
        "text-transform", "text-underline-offset", "text-underline-position",
        "text-wrap", "text-wrap-mode", "text-wrap-style", "visibility",
        "white-space", "white-space-collapse", "widows", "word-break",
        "word-spacing", "writing-mode",
        "-webkit-font-smoothing", "-webkit-text-size-adjust",
        "-webkit-text-stroke", "-webkit-text-stroke-color", "-webkit-text-stroke-width",
    ]

    /// Custom properties inherit too, and they're the ones most worth tracing:
    /// a `--brand` set five ancestors up is invisible in every other inspector.
    public static func isInheritable(_ property: String) -> Bool {
        property.hasPrefix("--") || inherited.contains(property)
    }
}
