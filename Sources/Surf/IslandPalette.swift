import AppKit
import SurfCore
import SwiftUI

/// Bridging an island's stored colour to and from SwiftUI.
///
/// `IslandTint` holds bare components so `SurfCore` can stay free of SwiftUI;
/// the conversions live here, on the one side that has both.
extension IslandTint {

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }

    /// Reads a colour back out of the picker.
    ///
    /// Converted through sRGB deliberately. The system picker will hand back
    /// colours in Display P3 or a named catalog space, and asking those for
    /// `.redComponent` directly either throws or silently answers in the wrong
    /// space — so a colour picked from the wide-gamut wheel would be stored as
    /// something else entirely and come back changed.
    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB)
            ?? NSColor(color).usingColorSpace(.deviceRGB)
        guard let resolved else {
            self = .surf
            return
        }
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent)
        )
    }

    /// Human-readable, for the picker's accessibility label. A colour the user
    /// mixed themselves gets its hex rather than an invented name.
    var label: String {
        presetName?.capitalized ?? hex
    }

    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

/// The emoji offered as quick picks when naming an island.
///
/// A short list *beside* the system picker rather than instead of it: the strip
/// shows these small, and most emoji are unreadable at that size or carry so
/// much detail they fight the tint behind them. These all read as a silhouette.
/// Anything else is a click away in Emoji & Symbols.
enum IslandSymbols {
    static let quickPicks = [
        "🏝️", "🌴", "🐚", "🏄", "🐠", "⛵️", "🪸", "🌊",
        "💼", "🏠", "🎓", "🔬", "🎮", "🛒", "✉️", "🎧",
    ]

    static let fallback = "🏝️"

    /// One emoji, whatever was typed or pasted.
    ///
    /// Measured in grapheme clusters, not characters: a flag, a skin-toned
    /// hand, or 🏝️ itself are each several scalars, and taking `first` on
    /// unicodeScalars would saw one in half and render a stray variation
    /// selector.
    static func firstSymbol(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cluster = trimmed.first else { return nil }
        return String(cluster)
    }
}
