import Foundation

/// Which CSS property a colour was found on.
///
/// The property is the cheapest and strongest evidence of what a colour is
/// doing. Chroma alone can't tell a surface from an accent — the same hex is a
/// background on a hero and a label on a badge — but `background-color` versus
/// `color` settles half the question before anything else is measured.
public enum ColorProperty: String, CaseIterable, Sendable {
    case background
    case text
    case border
    case outline
    case shadow
    case fill
    case stroke
    /// A `background-color` that is acting as ink rather than as a surface,
    /// because a `mask-image` is cutting a shape out of it.
    ///
    /// This is how icons are drawn now — one sprite masked to shape, coloured
    /// by the background. Treated as a background it is a dark surface, and the
    /// rule that keeps dark surfaces dark leaves it invisible on a dark page.
    /// It is really a glyph, and belongs with text. Wikipedia's whole toolbar
    /// is drawn this way.
    case maskedInk

    /// What the pair owes once transformed. Borders, outlines, and shadows are
    /// structure rather than prose, and WCAG holds them to the lower bar.
    public var requirement: Contrast.Requirement {
        switch self {
        // SVG fill often carries a wordmark, so it is held to the text bar.
        // A stroke is a drawn line and is held to the graphic one.
        case .text, .fill: .normalText
        case .border, .outline, .shadow, .stroke, .background, .maskedInk: .nonText
        }
    }

    /// Backgrounds are the ground other colours are judged against, rather
    /// than something judged itself.
    public var isBackground: Bool { self == .background }
    /// Prose, and the SVG paint that stands in for it. A neutral icon belongs
    /// with text — it inverts — rather than with surfaces, which would leave it
    /// the same colour as the page it sits on.
    var isReadable: Bool {
        self == .text || self == .fill || self == .stroke || self == .maskedInk
    }
    /// Lines drawn to separate things, whose job is separation rather than
    /// colour.
    var isSeparator: Bool { self == .border || self == .outline }
}

/// One sighting of a colour on the page, with the context that makes it
/// classifiable.
public struct ColorObservation: Equatable, Sendable {
    public var color: CSSColor
    public var property: ColorProperty
    /// Painted area in CSS pixels, as a fraction of the viewport. Area is the
    /// evidence that separates a masthead from a badge.
    public var areaFraction: Double
    /// Links, buttons, and anything with a button role — a strong accent signal
    /// independent of how saturated the colour happens to be.
    public var isInteractive: Bool
    /// 24px, or 18.5px bold, per WCAG's large-text definition.
    public var isLargeText: Bool

    /// The colour exactly as the page wrote it.
    ///
    /// Kept because the plan is looked up *by the page*, using whatever
    /// `getComputedStyle` hands back — `rgb(255, 255, 255)`, not `#ffffff`.
    /// Keying on our own normalised spelling instead produces a plan whose
    /// every entry is correct and whose every key misses.
    public var source: String?

    /// The colour this one is painted on top of.
    ///
    /// Legibility is a property of a pair, and the pair is the colour and what
    /// is immediately behind it — a label on a brand-coloured button is judged
    /// against that button, not against the page it happens to sit on. Without
    /// this the guarantee holds for body copy and quietly fails everywhere a
    /// surface has a colour of its own.
    public var backdrop: CSSColor?

    public init(
        color: CSSColor,
        property: ColorProperty,
        areaFraction: Double = 0,
        isInteractive: Bool = false,
        isLargeText: Bool = false,
        source: String? = nil,
        backdrop: CSSColor? = nil
    ) {
        self.color = color
        self.property = property
        self.areaFraction = areaFraction
        self.isInteractive = isInteractive
        self.isLargeText = isLargeText
        self.source = source
        self.backdrop = backdrop
    }

    /// The key a colour is looked up by when the mapping is applied.
    ///
    /// Property and colour together, because the page hands both back at apply
    /// time and neither alone is enough — the same grey is a surface behind a
    /// card and a rule between rows, and those want different answers.
    public var key: String { "\(property.rawValue)|\(source ?? color.css)" }
}

/// Decides what a colour is doing from the evidence around it.
public enum RoleClassifier {

    /// Above this share of the viewport, a coloured background is a wall rather
    /// than a badge. Deliberately generous: a masthead is a band across the top,
    /// not half the screen, and treating it as an accent leaves a saturated
    /// stripe glowing over a dark page.
    public static let largeSurfaceArea = 0.15

    public static func role(for observation: ColorObservation) -> ColorRole {
        let perceptual = OKLCH(observation.color.rgb)
        let isChromatic = perceptual.c >= ThemeTransform.accentChroma

        guard observation.property.isBackground else {
            // Anything that isn't a background is either prose or structure.
            // Chromatic prose is a brand colour — a link, a highlighted label —
            // and keeps its hue; neutral prose is text and inverts.
            if isChromatic { return .accent }
            return observation.property.isReadable ? .text : .surface
        }

        guard isChromatic else { return .surface }
        // A chromatic background: scale decides whether it reads as identity or
        // as lighting. An interactive one is a button however big it is.
        if observation.isInteractive { return .accent }
        return observation.areaFraction >= largeSurfaceArea ? .brandSurface : .accent
    }
}

/// The complete set of colour substitutions for one page.
///
/// Built in `SurfCore` from observations the page reports, so the decisions —
/// which colour is a brand, what it becomes, whether it still reads — are all
/// testable without a web view anywhere near them.
public struct ThemePlan: Equatable, Sendable {
    /// Keyed by `ColorObservation.key`; values are ready to write into CSS.
    public var replacements: [String: String]
    /// What the page's dominant background became. The page is painted with
    /// this before anything else, so there is no white flash to sit through.
    public var pageBackground: CSSColor

    public var isEmpty: Bool { replacements.isEmpty }
}

extension ThemePlan {

    /// Builds the plan.
    ///
    /// Colours are grouped by property and value, and each group is classified
    /// once from its largest sighting. Grouping matters for consistency as much
    /// as for speed: the same grey has to become the same dark grey everywhere
    /// it appears, or the page comes back subtly striped.
    public static func build(
        from observations: [ColorObservation],
        target: ColorSchemeTarget,
        establishedGround: CSSColor? = nil
    ) -> ThemePlan {
        let surface: OKLCH
        /// What the page is painted with. Held separately from `surface` so an
        /// established ground comes back as the same bytes rather than as the
        /// same colour — a value that drifts by a bit on every sweep is a
        /// declaration that keeps being rewritten for no reason.
        let ground: CSSColor

        if let establishedGround {
            // A second pass over a page already themed sees only what hasn't
            // been touched yet, so the largest background among them is some
            // panel rather than the page. Re-deriving the ground from that set
            // picks a colour at random and repaints the whole document with it
            // — a blue panel makes the page blue. The ground was settled on the
            // first pass and must not be reconsidered.
            surface = OKLCH(establishedGround.rgb)
            ground = establishedGround
        } else {
            // The dominant background sets the ground everything else is judged
            // against. Falling back to the scheme we're leaving is the right
            // guess: a page with no background declaration is showing the
            // browser's, which is white on the way to dark.
            let dominant = observations
                .filter(\.property.isBackground)
                .max { $0.areaFraction < $1.areaFraction }

            let color = dominant?.color ?? CSSColor(rgb: target == .dark ? .white : .black)
            // A chromatic page background is still a page background. It keeps
            // its hue and gives up its intensity — held at full chroma across
            // the whole document it stops being a brand and becomes a glare.
            let role = dominant.map(RoleClassifier.role(for:)) ?? .surface
            surface = ThemeTransform.transform(
                OKLCH(color.rgb),
                role: role == .surface ? .surface : .brandSurface,
                target: target
            )
            ground = CSSColor(rgb: surface.displayable, alpha: 1)
        }

        var groups: [String: ColorObservation] = [:]
        for observation in observations {
            // Keep the largest sighting of each colour-and-property pair: the
            // biggest thing a colour paints is the best evidence of its job.
            if let existing = groups[observation.key],
               existing.areaFraction >= observation.areaFraction {
                groups[observation.key] = ColorObservation(
                    color: existing.color,
                    property: existing.property,
                    areaFraction: existing.areaFraction,
                    isInteractive: existing.isInteractive || observation.isInteractive,
                    isLargeText: existing.isLargeText || observation.isLargeText,
                    source: existing.source,
                    backdrop: existing.backdrop
                )
            } else {
                groups[observation.key] = observation
            }
        }

        var replacements: [String: String] = [:]

        /// A colour that didn't move needs no rule written for it. Restating a
        /// value is not free: it's a declaration injected over the author's, at
        /// higher specificity, that has to go on being right.
        func record(_ key: String, _ result: OKLCH, _ observation: ColorObservation) {
            let replacement = CSSColor(rgb: result.displayable, alpha: observation.color.alpha)
            guard replacement.css != observation.color.css else { return }
            replacements[key] = replacement.css
        }

        // Backgrounds first, and keyed by their normalised spelling, so that
        // anything painted on one can be judged against what it *became*
        // rather than against what it was or against the page.
        var grounds: [String: OKLCH] = [:]
        for (key, observation) in groups where observation.property.isBackground {
            let role = RoleClassifier.role(for: observation)
            let result = ThemeTransform.transform(
                OKLCH(observation.color.rgb), role: role, target: target
            )
            grounds[observation.color.css] = result
            record(key, result, observation)
        }

        // Then everything painted on top of them.
        for (key, observation) in groups where !observation.property.isBackground {
            let role = RoleClassifier.role(for: observation)
            var result = ThemeTransform.transform(
                OKLCH(observation.color.rgb), role: role, target: target
            )

            // Its own backdrop where we know it — falling back to the page's
            // ground, which is what it sits on when nothing else intervenes.
            let ground = observation.backdrop.map {
                grounds[$0.css] ?? ThemeTransform.transform(
                    OKLCH($0.rgb), role: .surface, target: target
                )
            } ?? surface

            if observation.property.isSeparator, let backdrop = observation.backdrop {
                // Judged on separation rather than on contrast, and so not
                // repaired: the repair's floor is what flattens a heavy rule
                // and a decorative one into the same line.
                result = ThemeTransform.transformBorder(
                    OKLCH(observation.color.rgb),
                    on: OKLCH(backdrop.rgb),
                    newBackdrop: ground
                )
            } else {
                let requirement: Contrast.Requirement = observation.isLargeText
                    ? .largeText : observation.property.requirement
                result = ContrastRepair.repair(
                    foreground: result, background: ground, requirement: requirement
                ).foreground
            }

            record(key, result, observation)
        }

        return ThemePlan(replacements: replacements, pageBackground: ground)
    }
}

/// Whether a page needs a theme built for it at all, and what to judge that on.
///
/// This lived inline in the tab and produced two separate bugs there, both from
/// the same root: a page's *declared* background is frequently transparent, and
/// neither reading of that is safe. Taken as black it satisfies "already dark",
/// so every site that never set a background is left in light mode forever.
/// Taken as white it satisfies "needs work", so a site with a genuine dark mode
/// gets restyled whenever it's caught before its background has painted.
///
/// The resolution is to stop asking what the page declared and look at what it
/// painted — and to treat "nothing painted yet" as a reason to wait rather than
/// as evidence of anything.
public enum SchemeDecision {

    /// How close to the target a page has to be already for us to leave it be.
    ///
    /// Asymmetric because the two mistakes are not equal. Wrongly restyling a
    /// site that has its own dark mode replaces a designer's work with an
    /// approximation, which is worse than wrongly leaving a dim page alone.
    static let darkEnough = 0.35
    static let lightEnough = 0.7

    /// The colour a decision should be made on, or nil if the page hasn't
    /// painted anything to decide from.
    public static func decisionGround(
        declared: String?,
        observations: [ColorObservation]
    ) -> CSSColor? {
        if let declared, let color = CSSColor(css: declared), color.alpha > 0.5 {
            return color
        }
        // Nothing declared, so the ground is whatever covers the most of it —
        // which is what the eye takes for the background regardless of which
        // element happens to be carrying it.
        return observations
            .filter(\.property.isBackground)
            .max { $0.areaFraction < $1.areaFraction }?
            .color
    }

    /// Whether a page on this ground is already in the scheme the user asked
    /// for, and should be left exactly as its authors drew it.
    public static func alreadySatisfies(
        _ target: ColorSchemeTarget,
        ground: CSSColor
    ) -> Bool {
        let lightness = OKLCH(ground.rgb).l
        return target == .dark ? lightness < darkEnough : lightness > lightEnough
    }
}
