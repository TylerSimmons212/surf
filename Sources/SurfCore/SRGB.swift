import Foundation

/// A colour in sRGB, each channel 0...1.
///
/// Deliberately not `NSColor`: everything that decides what a synthesised theme
/// looks like has to be testable, and `SurfCore` can't import AppKit. The
/// bridge to `NSColor` lives in the app target, on the other side of this line.
public struct SRGB: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let black = SRGB(r: 0, g: 0, b: 0)
    public static let white = SRGB(r: 1, g: 1, b: 1)

    /// Whether every channel is inside the displayable range.
    ///
    /// The tolerance matters: a colour that round-trips through Oklab lands a
    /// hair outside on the last bit, and treating that as out-of-gamut would
    /// send the mapper hunting for chroma to remove from a colour that was
    /// always fine.
    public var isInGamut: Bool {
        let limits = -1e-6...(1 + 1e-6)
        return limits.contains(r) && limits.contains(g) && limits.contains(b)
    }

    public var clamped: SRGB {
        SRGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }

    /// Flattens a translucent colour against what sits behind it.
    ///
    /// Contrast is a property of what reaches the eye, so a half-transparent
    /// grey over white and the same grey over black are different colours for
    /// every purpose here, and have to be resolved before anything is measured.
    public func composited(over backdrop: SRGB, alpha: Double) -> SRGB {
        let a = min(max(alpha, 0), 1)
        return SRGB(
            r: r * a + backdrop.r * (1 - a),
            g: g * a + backdrop.g * (1 - a),
            b: b * a + backdrop.b * (1 - a)
        )
    }

    // MARK: - Hex

    /// Parses `#rgb`, `#rrggbb`, and the 4- and 8-digit forms with alpha.
    ///
    /// Alpha is accepted and discarded rather than rejected: a page that writes
    /// `#00000080` is naming a colour we still have to transform, and refusing
    /// to parse it would silently leave that declaration untouched.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }

        // Expand shorthand by doubling each digit — #abc is #aabbcc, not #0abc.
        if text.count == 3 || text.count == 4 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8,
              text.allSatisfy(\.isHexDigit),
              let value = UInt32(text.prefix(6), radix: 16)
        else { return nil }

        self.init(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255
        )
    }

    /// Round-trips through `init(hex:)`. Clamped first, since a colour arriving
    /// from Oklab can sit fractionally outside the cube.
    public var hex: String {
        let c = clamped
        let channel = { (v: Double) in Int((v * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(c.r), channel(c.g), channel(c.b))
    }
}
