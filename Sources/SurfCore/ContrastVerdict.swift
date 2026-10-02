import Foundation

/// The selected element's text contrast, judged — the ratio, the WCAG
/// verdicts at both levels, and when AA fails, a repaired colour from the
/// engine that has been sitting in this module with 679 tests and no UI.
///
/// The large-text rule is encoded rather than remembered: WCAG's thresholds
/// drop to 3.0 (AA) and 4.5 (AAA) for text that is at least 24 CSS pixels,
/// or at least ~18.66 pixels when bold — the "14pt bold / 18pt" clause, in
/// the pixel terms a computed style actually speaks.
public struct ContrastVerdict: Sendable, Equatable {

    public var foreground: SRGB
    public var background: SRGB
    public var ratio: Double
    public var isLargeText: Bool
    public var passesAA: Bool
    public var passesAAA: Bool
    /// A foreground that would pass AA, present only when the current one
    /// doesn't — hue held, chroma surrendered only as far as legibility
    /// demands, per the repair engine's guarantees.
    public var suggestion: SRGB?

    public init(
        foreground: SRGB,
        background: SRGB,
        fontSizePx: Double,
        isBold: Bool
    ) {
        self.foreground = foreground
        self.background = background

        let large = fontSizePx >= 24 || (isBold && fontSizePx >= 18.66)
        isLargeText = large

        let ratio = Contrast.ratio(foreground, background)
        self.ratio = ratio

        let aa = large ? 3.0 : 4.5
        let aaa = large ? 4.5 : 7.0
        passesAA = ratio >= aa
        passesAAA = ratio >= aaa

        if passesAA {
            suggestion = nil
        } else {
            let outcome = ContrastRepair.repair(
                foreground: OKLCH(foreground),
                background: OKLCH(background),
                requirement: large ? .largeText : .normalText,
                moving: .foreground
            )
            suggestion = outcome.isLegible ? outcome.foreground.displayable : nil
        }
    }

    /// `700` and up is bold for the large-text clause; computed font-weight
    /// is numeric text like "400" or a keyword on old engines.
    public static func isBoldWeight(_ weight: String) -> Bool {
        if let numeric = Double(weight) { return numeric >= 700 }
        return weight == "bold" || weight == "bolder"
    }
}

extension SRGB {
    /// `rgb(64 128 255)` — a value the style editor can write back.
    public var cssText: String {
        func channel(_ value: Double) -> Int {
            Int((value.clamped01 * 255).rounded())
        }
        return "rgb(\(channel(r)) \(channel(g)) \(channel(b)))"
    }

    private var clampedComponents: SRGB { clamped }
}

extension Double {
    fileprivate var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
