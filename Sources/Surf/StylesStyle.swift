import SurfCore
import SwiftUI

/// The Styles pane's syntax palette, chosen twice — once for each appearance.
enum StylesStyle {
    static let selector = DevToolsTheme.adaptive(
        light: (0.16, 0.34, 0.66), dark: (0.60, 0.78, 1.00)
    )
    static let layer = DevToolsTheme.adaptive(
        light: (0.48, 0.30, 0.70), dark: (0.78, 0.64, 0.98)
    )
    static let variable = DevToolsTheme.adaptive(
        light: (0.10, 0.45, 0.48), dark: (0.44, 0.86, 0.86)
    )
    static let important = DevToolsTheme.adaptive(
        light: (0.72, 0.18, 0.20), dark: (1.00, 0.55, 0.55)
    )
}
