import Foundation

/// The element facts inactive-CSS reasoning runs on. Four values, read once
/// per selection by the agent — everything here is about *this* element and
/// its parent, never the whole page.
public struct StyleContext: Sendable, Equatable {
    public var display: String
    public var position: String
    /// The parent's computed display — what decides whether this element is a
    /// flex or grid *item*.
    public var parentDisplay: String
    /// Replaced elements (img, input, video…) take sizes even inline — the
    /// exception that keeps the inline-sizing rule honest.
    public var isReplaced: Bool

    public init(
        display: String = "",
        position: String = "",
        parentDisplay: String = "",
        isReplaced: Bool = false
    ) {
        self.display = display
        self.position = position
        self.parentDisplay = parentDisplay
        self.isReplaced = isReplaced
    }
}

/// Why a declaration that parses fine — and may even have won its cascade —
/// still does nothing here.
///
/// The other half of the Styles pane's thesis. The cascade card answers "why
/// did this lose"; this answers "why did winning not matter", which is the
/// question behind a solid share of all CSS confusion: `width` on an inline
/// span, `top` on a static element, `justify-content` on a block. Firefox
/// pioneered this as Inactive CSS; every rule here follows its shape.
///
/// The discipline is that a wrong claim is worse than a missing one. Every
/// rule fires only on conditions that are provably sufficient from the four
/// facts in `StyleContext` — anything requiring knowledge we don't carry
/// (multi-column for `gap`, block alignment for `align-content`, scroll
/// containers for `overflow`) says nothing rather than guessing. When in
/// doubt, silence.
public enum CSSInactive {

    /// One sentence, in the tool's voice, or nil when the declaration works
    /// (or when we can't be sure it doesn't).
    public static func reason(for property: String, in context: StyleContext) -> String? {
        let name = property.lowercased()
        let display = context.display
        let parent = context.parentDisplay

        func isFlexContainer(_ display: String) -> Bool {
            display == "flex" || display == "inline-flex"
        }
        func isGridContainer(_ display: String) -> Bool {
            display == "grid" || display == "inline-grid"
        }

        // Sizing on non-replaced inline elements.
        if Self.sizing.contains(name), display == "inline", !context.isReplaced {
            return "an inline element ignores \(name) — it sizes to its text; "
                + "a display like inline-block or block would take it"
        }

        // vertical-align off inline contexts.
        if name == "vertical-align", display != "table-cell", !display.hasPrefix("inline"),
           display != "" {
            return "vertical-align only moves inline-level boxes and table "
                + "cells — this element is display: \(display)"
        }

        // Offsets on static elements.
        if Self.offsets.contains(name), context.position == "static" {
            return "\(name) needs a positioned element — position is static, "
                + "so there is nothing to offset from"
        }
        if name == "z-index", context.position == "static",
           !isFlexContainer(parent), !isGridContainer(parent) {
            // Flex and grid items stack by z-index even when static — the
            // exception that keeps this from being the offsets rule.
            return "z-index needs a positioned element, or a flex or grid "
                + "item — this is a static child of a \(parent.isEmpty ? "block" : parent)"
        }

        // Container properties on the wrong kind of container.
        if Self.flexContainerOnly.contains(name), !isFlexContainer(display), !display.isEmpty {
            return "\(name) directs a flex container's children — this "
                + "element is display: \(display), not flex"
        }
        if Self.flexOrGridContainer.contains(name),
           !isFlexContainer(display), !isGridContainer(display), !display.isEmpty {
            return "\(name) aligns a flex or grid container's children — "
                + "this element is display: \(display)"
        }
        if Self.gridContainerOnly.contains(name), !isGridContainer(display), !display.isEmpty {
            return "\(name) defines a grid — this element is display: "
                + "\(display), not grid"
        }

        // Item properties under the wrong kind of parent.
        if Self.flexItemOnly.contains(name), !isFlexContainer(parent), !parent.isEmpty {
            return "\(name) is for flex items — the parent is display: "
                + "\(parent), so this element isn't one"
        }
        if Self.gridItemOnly.contains(name), !isGridContainer(parent), !parent.isEmpty {
            return "\(name) places a grid item — the parent is display: "
                + "\(parent), not a grid"
        }
        if name == "order",
           !isFlexContainer(parent), !isGridContainer(parent), !parent.isEmpty {
            return "order rearranges flex or grid items — the parent is "
                + "display: \(parent), so document order stands"
        }

        // float inside flex and grid, where it is defined to do nothing.
        if name == "float", isFlexContainer(parent) || isGridContainer(parent) {
            return "float does nothing to a flex or grid item — the parent's "
                + "layout places this element"
        }

        return nil
    }

    static let sizing: Set<String> = [
        "width", "height", "min-width", "min-height", "max-width", "max-height",
    ]
    static let offsets: Set<String> = ["top", "right", "bottom", "left", "inset"]
    static let flexContainerOnly: Set<String> = [
        "flex-direction", "flex-wrap", "flex-flow",
    ]
    static let flexOrGridContainer: Set<String> = [
        "justify-content", "align-items", "justify-items",
    ]
    static let gridContainerOnly: Set<String> = [
        "grid-template-columns", "grid-template-rows", "grid-template-areas",
        "grid-template", "grid-auto-columns", "grid-auto-rows", "grid-auto-flow",
    ]
    static let flexItemOnly: Set<String> = [
        "flex", "flex-grow", "flex-shrink", "flex-basis",
    ]
    static let gridItemOnly: Set<String> = [
        "grid-column", "grid-row", "grid-area",
        "grid-column-start", "grid-column-end", "grid-row-start", "grid-row-end",
    ]
}
