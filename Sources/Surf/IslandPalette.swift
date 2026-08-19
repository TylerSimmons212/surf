import SurfCore
import SwiftUI

/// The colours islands are told apart by.
///
/// Fixed, like `OceanTide`, and for the same reason: an island's colour is how
/// you know at a glance which identity you're browsing as, so it can't be
/// whatever blue the system accent happens to be this week. Two of them are
/// lifted straight from the tide so the strip sits in the same water as the
/// loading border rather than beside it.
extension IslandTint {

    var color: Color {
        switch self {
        case .surf: OceanTide.surf
        case .lagoon: OceanTide.shallow
        case .kelp: Color(red: 0.20, green: 0.68, blue: 0.48)
        case .coral: Color(red: 0.95, green: 0.44, blue: 0.42)
        case .sand: Color(red: 0.88, green: 0.72, blue: 0.42)
        case .dusk: Color(red: 0.55, green: 0.45, blue: 0.85)
        }
    }

    /// Human-readable, for the tint picker.
    var label: String {
        switch self {
        case .surf: "Surf"
        case .lagoon: "Lagoon"
        case .kelp: "Kelp"
        case .coral: "Coral"
        case .sand: "Sand"
        case .dusk: "Dusk"
        }
    }
}

/// The emoji offered when naming an island.
///
/// A short list rather than the system emoji picker: the strip shows these at
/// 13pt beside each other, and most emoji are unreadable at that size or carry
/// so much detail they fight the tint behind them. These are all legible as a
/// silhouette.
enum IslandSymbols {
    static let all = [
        "🏝️", "🌴", "🐚", "🏄", "🐠", "⛵️", "🪸", "🌊",
        "💼", "🏠", "🎓", "🔬", "🎮", "🛒", "✉️", "🎧",
    ]

    static let fallback = "🏝️"
}
