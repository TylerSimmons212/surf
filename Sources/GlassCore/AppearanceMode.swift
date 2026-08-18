/// Which colour scheme the browser renders in.
///
/// Three states rather than a Bool, because "follow the system" is a real
/// choice and not merely the absence of one. A user who never opens Settings
/// still expects the browser to go dark at sunset along with everything else,
/// so the shipped default has to mean *track the OS*, not *stay light*.
public enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The shipped default. Named rather than relying on `.system` being first
    /// in the case list, which is the kind of thing a reorder silently breaks.
    public static let `default` = AppearanceMode.system

    /// Reads a value out of stored preferences.
    ///
    /// Deliberately total: an unset key reads back as `nil` and a file edited
    /// by hand can hold anything at all. Both have to land on `.system`, or the
    /// browser starts up forcing a scheme nobody chose.
    public init(stored value: String?) {
        self = value.flatMap(AppearanceMode.init(rawValue:)) ?? .default
    }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Whether the app should override the OS appearance at all.
    ///
    /// The distinction matters beyond tidiness: overriding with the value the
    /// system already has is *not* the same as not overriding, because an
    /// override is frozen. A window pinned to light stays light when the Mac
    /// switches to dark at sunset; a window that never overrode follows.
    public var overridesSystem: Bool { self != .system }

    /// What pages should actually render as, once the OS has had its say.
    public func resolved(systemIsDark: Bool) -> ColorSchemeTarget {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A concrete scheme, with the ambiguity of `.system` already resolved away.
///
/// Separate from `AppearanceMode` because the two answer different questions.
/// The mode is what the user asked for and can be indefinite; this is what the
/// pixels have to be, and never is. It also names the direction the Phase 2
/// colour transform runs in — synthesising a dark theme for a light-only site
/// and a light theme for a dark-only one are the same operation with the ends
/// swapped.
public enum ColorSchemeTarget: String, CaseIterable, Sendable {
    case light
    case dark

    /// The scheme a site would have to be painted in for us to leave it alone.
    public var opposite: ColorSchemeTarget { self == .dark ? .light : .dark }
}
