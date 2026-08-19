import SwiftUI

/// The water the loading border is made of.
///
/// The border used to be drawn in `Color.accentColor`, which is whatever blue
/// the user set in System Settings — so on a machine with a pink or graphite
/// accent, the one piece of chrome named after the ocean wasn't blue at all.
/// These are fixed on purpose: this is the app's own colour, not the system's.
///
/// Ordered shallow-to-deep the way water actually reads looking down at it,
/// which is what makes a gradient across them look like sea rather than like a
/// blue-to-green ramp: the light end is foam and the dark end is depth.
enum OceanTide {
    /// Spray at the crest — the brightest thing on screen, used sparingly.
    static let foam = Color(red: 0.78, green: 0.97, blue: 0.98)
    /// Shallow water over sand.
    static let shallow = Color(red: 0.28, green: 0.83, blue: 0.89)
    /// The body of the wave.
    static let surf = Color(red: 0.10, green: 0.60, blue: 0.85)
    /// Open water.
    static let ocean = Color(red: 0.05, green: 0.38, blue: 0.72)
    /// Where it stops being blue.
    static let deep = Color(red: 0.04, green: 0.22, blue: 0.50)

    /// One representative tone, for the places that need a single colour rather
    /// than a ramp — shadows and glows, which take a `Color` and not a gradient.
    static let glow = surf

    /// The ramp as it runs around the window, from the top-centre start
    /// clockwise and back.
    ///
    /// Both ends are `deep` deliberately. The stroke is a closed loop, so any
    /// two different endpoints meet at twelve o'clock as a visible seam — and
    /// twelve o'clock is exactly where the eye is, because that's where the
    /// sweep starts and finishes.
    static let tideStops: [Gradient.Stop] = [
        .init(color: deep, location: 0.00),
        .init(color: ocean, location: 0.16),
        .init(color: surf, location: 0.38),
        .init(color: shallow, location: 0.58),
        .init(color: surf, location: 0.78),
        .init(color: ocean, location: 0.92),
        .init(color: deep, location: 1.00),
    ]

    /// Wrapped around the window rather than run across it: the stroke *is* a
    /// circuit, so an angular sweep keeps each colour at a fixed place on the
    /// frame instead of sliding along it as the window is resized.
    static var tide: AngularGradient {
        AngularGradient(
            gradient: Gradient(stops: tideStops),
            center: .center,
            // Zero degrees is due east; the border starts at twelve o'clock.
            angle: .degrees(-90)
        )
    }
}
