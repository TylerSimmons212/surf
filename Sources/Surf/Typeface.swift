import AppKit
import SwiftUI

/// Surf's own two faces, and the weight axis pinned deliberately.
///
/// Both are variable fonts with a single `wght` axis, and both report their
/// *lightest* instance as the family default — Outfit opens at Thin, Figtree at
/// Light. So `Font.custom("Outfit", size:)` is not Outfit Regular; it is a
/// hairline, and nothing about the call site says so. Every use goes through
/// here instead, where the axis is set explicitly.
enum Typeface {

    /// The display face: the wordmark, and nothing small.
    ///
    /// Outfit's x-height is 0.46 of its em against SF Pro's 0.51, which is what
    /// gives it air when it is set large and what makes it illegible when it
    /// isn't. It has no italics.
    static func outfit(size: CGFloat, weight: CGFloat = 600) -> Font {
        Font(variable("Outfit", size: size, weight: weight))
    }

    /// The text face, for chrome at 12pt and up.
    ///
    /// Sized to sit beside SF Pro without a seam: x-height 0.500 against SF
    /// Pro's 0.508, cap height 0.700 against 0.705. Below about 12pt the system
    /// font's optical sizing wins and the dev tools keep it.
    static func figtree(size: CGFloat, weight: CGFloat = 400) -> Font {
        Font(variable("Figtree", size: size, weight: weight))
    }

    /// Builds the instance at an exact axis position rather than asking for a
    /// named style, so a weight we don't ship a name for is still reachable and
    /// a family whose default is Thin can't quietly answer for Regular.
    private static func variable(_ family: String, size: CGFloat, weight: CGFloat) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            // 0x77676874 is 'wght'. The key takes the axis's four-byte tag.
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [0x77676874: weight],
        ])
        // A missing family here would be a silent fall back to the system font,
        // which looks enough like a design choice to survive review.
        return NSFont(descriptor: descriptor, size: size)
            ?? .systemFont(ofSize: size, weight: weight >= 600 ? .semibold : .regular)
    }
}
