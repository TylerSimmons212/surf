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

    /// Code, values, log output — anything that came from the page.
    static let mono = Font.system(size: 11.5).monospaced()
    /// Chrome: labels, filters, counts.
    static let chrome = Font.system(size: 11)
    /// Secondary chrome: source locations, hints.
    static let caption = Font.system(size: 10)

    // MARK: - Surfaces

    static let corner: CGFloat = 6
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
