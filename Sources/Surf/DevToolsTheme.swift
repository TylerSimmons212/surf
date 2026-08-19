import AppKit
import SurfCore
import SwiftUI

/// The panel's shared measurements and colours.
///
/// Gathered in one place because dev tools is dense: a log row, a property row
/// and a tree row all sit millimetres apart, and if each picks its own font
/// size and padding the pane reads as three different apps stacked together.
/// One scale, applied everywhere, is what makes it feel like a tool.
enum DevToolsTheme {

    // MARK: - Rhythm

    /// The base unit. Every gap is a multiple, so nothing lands off-grid.
    static let unit: CGFloat = 4

    /// Horizontal inset for chrome — bars, headers, footers.
    static let barInset: CGFloat = unit * 3      // 12
    static let barVertical: CGFloat = unit * 1.5 // 6

    /// A single line of output. Snug, because density is the point: the more
    /// of the log you can see at once, the less scrolling to understand it.
    static let rowInset: CGFloat = unit * 2.5    // 10
    static let rowVertical: CGFloat = unit * 0.75 // 3

    /// How far each level of an expanded object steps in. Small enough that
    /// deep nesting stays on screen, wide enough to read as a level.
    static let indent: CGFloat = unit * 3.5      // 14

    /// The disclosure triangle's column. Fixed so values line up whether or
    /// not they can be opened.
    static let discloseWidth: CGFloat = unit * 2.5 // 10

    // MARK: - Type

    /// The panel speaks in two voices, and which one a string gets is decided
    /// by *who said it* rather than by how important it looks.
    ///
    /// `mono` is the page's voice: a selector, a value, a header, a line of
    /// log output — text this tool is quoting rather than writing. Everything
    /// else is the tool's own voice, and belongs in the system font, because
    /// a sentence set in a monospaced face reads as data the page emitted
    /// instead of as something the inspector is telling you.
    ///
    /// That distinction had drifted badly. An explanation like "lost on
    /// specificity — one class against two" is the most valuable string in
    /// the Styles pane and was set at 10pt in tertiary grey, while the value
    /// it explains sat above it at 11.5pt: the tool's own reasoning rendered
    /// as the least important thing on screen, smaller than the data it was
    /// about. Several places had gone further and hardcoded 9pt.
    ///
    /// So `prose` is deliberately the largest of these. Nothing the tool says
    /// in its own words should be smaller than what it is quoting.

    /// Code, values, log output — anything that came from the page.
    static let mono = Font.system(size: 11.5).monospaced()
    /// The tool's own words: a verdict, a reason, an explanation of what a
    /// number means or why a rule lost.
    static let prose = Font.system(size: 12)
    /// Chrome: labels, filters, counts.
    static let chrome = Font.system(size: 11)
    /// Secondary chrome: source locations, hints. The floor of the *reading*
    /// scale — anything meant to be read as words stops here, and anything
    /// that reads as a sentence wants `prose`.
    static let caption = Font.system(size: 10)

    /// A count or a one-word state carried in a chip: "3", "no events",
    /// "!important". Deliberately outside the reading scale, because a badge
    /// is a glyph you register rather than text you read — the same reason a
    /// notification bubble is smaller than any label near it.
    ///
    /// Named so it stops being scattered magic numbers. There are still
    /// hardcoded 8pt and 9pt sizes elsewhere in the panel that belong here;
    /// they are worth converting, but as a sweep with eyes on it rather than
    /// blind.
    static let badge = Font.system(size: 9, weight: .semibold)

    // MARK: - Surfaces

    static let corner: CGFloat = 6

    /// A card: a grouped surface that separates by the gap around it rather
    /// than by a rule drawn through the layout.
    ///
    /// Full-bleed `Divider()`s are the console tell — Storage stacks six of
    /// them — and they force every region to be the full width of the pane.
    /// Insetting content and letting whitespace do the separating is most of
    /// what makes a dense tool read as designed rather than as emitted.
    static let cardCorner: CGFloat = 10
    static let cardPadding: CGFloat = unit * 2.5   // 10
    static let cardGap: CGFloat = unit * 1.5       // 6
    static let cardFill = Color.primary.opacity(0.035)
    static let cardStroke = Color.primary.opacity(0.08)

    /// The pane switcher's column: wide enough for a glyph with a comfortable
    /// target around it, narrow enough to read as chrome rather than sidebar.
    static let railWidth: CGFloat = unit * 11          // 44
    static let railItemWidth: CGFloat = unit * 8       // 32
    static let railItemHeight: CGFloat = unit * 7      // 28
    static let railCorner: CGFloat = 7

    /// A chosen thing — the rail's current pane, an engaged filter chip.
    /// Every pane had picked this same value independently; it lives here now
    /// so a future change to how selection reads is one edit.
    static let selectedFill = Color.accentColor.opacity(0.18)
    /// Hover feedback, and the resting fill of a control.
    static let hoverFill = Color.primary.opacity(0.06)
    static let inputFill = Color.primary.opacity(0.05)
    /// Row striping for what you typed, so the conversation is legible at a
    /// glance without colour doing the work.
    static let inputFill2 = Color.primary.opacity(0.04)

    // MARK: - Syntax colour

    /// A colour that answers differently in light and dark.
    ///
    /// Syntax palettes do not survive being inverted: a green picked to read
    /// against white is muddy against near-black, and a purple dark enough to
    /// be legible on paper disappears entirely. Each of these is chosen twice.
    static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }
}
