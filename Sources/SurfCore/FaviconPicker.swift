import Foundation

/// One `<link rel="icon">` found in a page's head.
public struct FaviconCandidate: Equatable, Sendable, Decodable {
    public var href: String
    /// The raw `sizes` attribute: "32x32", "16x16 32x32", "any", or empty.
    public var sizes: String

    public init(href: String, sizes: String = "") {
        self.href = href
        self.sizes = sizes
    }
}

/// Chooses which declared icon to actually download.
///
/// Pages routinely declare five or six icons at different sizes. Picking badly
/// means either a blurry upscale from a 16px icon or downloading a 512px PNG to
/// render at 13 points.
public enum FaviconPicker {

    /// Rendered at ~16pt, so 32px covers Retina exactly.
    private static let idealPixelSize = 32

    public static func best(from candidates: [FaviconCandidate], origin: String) -> String? {
        let usable = candidates.filter { !$0.href.isEmpty }

        guard !usable.isEmpty else {
            // Every site is entitled to an implicit /favicon.ico even with no
            // <link> tag at all, so fall back to the well-known path.
            return origin.isEmpty ? nil : origin + "/favicon.ico"
        }

        return usable.min { lhs, rhs in
            score(lhs) < score(rhs)
        }?.href
    }

    /// Lower is better: distance from the ideal size, with oversized icons
    /// penalised only half as much as undersized ones — downscaling looks fine,
    /// upscaling looks bad.
    private static func score(_ candidate: FaviconCandidate) -> Int {
        guard let pixels = largestDeclaredSize(in: candidate.sizes) else {
            // Undeclared size, e.g. a plain .ico. Usable, but a declared size
            // is a better bet, so rank it just behind a good match.
            return 40
        }
        // "any" means SVG: scales perfectly to any size, so it beats even an
        // exact pixel match (which also scores 0 — hence -1, not 0).
        if pixels == .max { return -1 }

        let delta = pixels - idealPixelSize
        return delta >= 0 ? delta / 2 : -delta
    }

    /// Parses "16x16 32x32" -> 32, and "any" -> .max.
    private static func largestDeclaredSize(in sizes: String) -> Int? {
        let tokens = sizes.lowercased().split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }
        if tokens.contains("any") { return .max }

        let values = tokens.compactMap { token -> Int? in
            Int(token.split(separator: "x").first ?? "")
        }
        return values.max()
    }
}
