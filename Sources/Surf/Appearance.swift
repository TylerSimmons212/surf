import AppKit
import SurfCore

extension AppearanceMode {

    /// AppKit's name for this scheme, or `nil` to stop overriding entirely.
    ///
    /// `nil` is not a missing value here, it's the whole of `.system`: clearing
    /// `NSApp.appearance` puts the app back to inheriting, which is the only
    /// way it keeps following the Mac when that switches at sunset. Setting
    /// `.aqua` because the system happens to be light right now would look
    /// identical and behave differently.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Applies the appearance preference to the app.
///
/// There is no colour-scheme API on `WKWebView` — nothing in `WKWebView.h`,
/// `WKWebViewConfiguration.h`, or `WKWebpagePreferences.h` as of the macOS 27
/// SDK. What WebKit actually reads is the view's `effectiveAppearance`, which
/// it maps straight onto the `prefers-color-scheme` media query and restyles
/// live when it changes.
///
/// So this sets exactly one thing, on `NSApplication`, and lets AppKit's
/// inheritance carry it everywhere: every window, the SwiftUI chrome, the
/// pop-out panel, and every tab's web view, including tabs created later. A
/// `WKWebView` sets no appearance of its own, so nothing has to be walked and
/// nothing can be missed.
///
/// The per-tab lever is the same property one level down — `webView.appearance`
/// overrides what the app hands it — which is where per-site exceptions will
/// hook in without disturbing any of this.
@MainActor
enum AppearanceController {

    static var current: AppearanceMode {
        AppearanceMode(stored: SurfDefaults.store.string(forKey: PreferenceKeys.appearanceMode))
    }

    static func apply(_ mode: AppearanceMode = current) {
        NSApp.appearance = mode.nsAppearance
        notifyChanged()
    }

    /// Tells every open tab that the scheme, or the decision to synthesise one,
    /// has moved. Posted rather than pushed because tabs come and go and the
    /// session shouldn't have to know which of them care.
    static func notifyChanged() {
        NotificationCenter.default.post(name: .surfAppearanceChanged, object: nil)
    }

    /// What the *Mac* is set to, regardless of what we've overridden it with.
    ///
    /// Read from the global domain rather than from `NSApp.effectiveAppearance`,
    /// which is the wrong source the moment an override is in place: with the
    /// app pinned to dark it reports dark on a light Mac, so anything asking
    /// "what would System mode give us?" would get its own answer back.
    ///
    /// The key is absent entirely when the Mac is in light mode — Apple never
    /// writes `"Light"` — so a missing value is the light case, not a failure.
    static var systemIsDark: Bool {
        SurfDefaults.store.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// The scheme pages are actually being painted in right now.
    static var resolved: ColorSchemeTarget {
        current.resolved(systemIsDark: systemIsDark)
    }
}

extension Notification.Name {
    static let surfAppearanceChanged = Notification.Name("surfAppearanceChanged")
}

/// Whether Surf should restyle sites that don't offer the requested scheme.
enum ThemePreferences {
    static var isEnabled: Bool {
        SurfDefaults.store.bool(forKey: PreferenceKeys.synthesizeTheme)
    }
}

extension SRGB {
    /// The AppKit side of the line. `SurfCore` deals in numbers so its
    /// decisions stay testable; this is the one place they become a colour the
    /// window server understands.
    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
